#!/usr/bin/env python3
"""Build, discover, run and account for the official serial Swift test shards."""
import json
from pathlib import Path
import re
import subprocess
import sys

SHARDS = 6  # About 150 discovered test definitions per fresh test host.
ROOT = Path('build/ci')
STRICT = ['--build-system', 'native', '-Xswiftc', '-warnings-as-errors',
          '-Xcc', '-Wall', '-Xcc', '-Wextra', '-Xcc', '-Werror']
SUMMARY = re.compile(r'Test run with [1-9][0-9]* tests?(?: in [0-9]+ suites?)? passed')
XCTEST = re.compile(r"^Test Case '-\[([^ ]+) ([^]]+)\]' passed ", re.M)
SWIFT = re.compile(r'^✔ Test (.+?\)) (?:with \d+ test cases )?passed ', re.M)
SKIPPED = re.compile(r'^➜ Test (.+?\)) skipped(?:[ .]|$)', re.M)
STARTED = re.compile(r'^◇ Test (.+?\)) started\.', re.M)
FINISHED = re.compile(r'^[✔✘➜] Test (.+?\)) (?:with \d+ test cases )?(?:passed|failed|skipped)(?:[ .]|$)', re.M)
XCTEST_EVENT = re.compile(r"^Test Case '-\[([^ ]+) ([^]]+)\]' (started|passed|failed|skipped)(?:[ .]|$)", re.M)
# Existing host integration probes, disabled unless their owners explicitly opt in.
OPT_IN_TESTS = frozenset({
    'TinyStatsCoreTests.ICMPLoopbackTests/nativeIPv4AndIPv6Echo()',
    'TinyStatsTrafficTests.liveKernelTrafficAccountsOnlyOwnedLoopbackPayloadAndFinalCounters()',
    'TinyStatsTrafficTests.liveModernSubscriptionReachesTheKernelAndReportsTheUnprivilegedDenial()',
    'TinyStatsUITests.menuBarNativeStatusItemOrderMigratesAndRebuildsOnHost()',
})


def discover(output):
    # SwiftPM forwards these two test-host stderr markers during discovery.
    evidence = {'Test host evidence: process start', 'Test host evidence: atexit'}
    tests = [line for line in output.splitlines() if line not in evidence]
    if not tests or len(set(tests)) != len(tests):
        raise ValueError('empty or duplicate discovery')
    if any(not re.fullmatch(r'[\w.]+/[\w]+|[\w./]+\([^\n]*\)', t) for t in tests):
        raise ValueError('unrecognized discovery entry')
    # Swift Testing prints the function signature without its module/suite.
    names = [t.rsplit('/', 1)[-1].rsplit('.', 1)[-1] for t in tests if t.endswith(')')]
    if len(names) != len(set(names)):
        raise ValueError('ambiguous Swift Testing names in discovery')
    return sorted(tests)


def partition(tests, count=SHARDS):
    shards = [[] for _ in range(count)]
    # Distribute each framework independently so every shard has a Swift summary.
    for group in ([t for t in tests if not t.endswith(')')], [t for t in tests if t.endswith(')')]):
        for i, test in enumerate(group):
            shards[i % count].append(test)
    if any(not any(t.endswith(')') for t in shard) for shard in shards):
        raise ValueError('each shard requires Swift Testing cases')
    return shards


def check(discovered, shards, results, opt_in=OPT_IN_TESTS, first_shard=1):
    if not discovered or not opt_in <= set(discovered):
        raise ValueError(f'empty discovery or stale opt-in entries: {sorted(opt_in - set(discovered))}')
    if len(results) != len(shards):
        raise ValueError('missing shard results')
    swift_names = {t.rsplit('/', 1)[-1].rsplit('.', 1)[-1]: t for t in discovered if t.endswith(')')}
    seen = []
    counts = []
    for i, (assigned, (code, log)) in enumerate(zip(shards, results)):
        if code or not SUMMARY.search(log):
            raise ValueError(f'shard {i + first_shard} failed or lacks completion summary')
        passed = [f'{suite}/{name}' for suite, name in XCTEST.findall(log)]
        skipped = []
        for names, target in ((SWIFT.findall(log), passed), (SKIPPED.findall(log), skipped)):
            for name in names:
                if name not in swift_names:
                    raise ValueError(f'unrecognized Swift test reported: {name}')
                target.append(swift_names[name])
        unknown_skips = set(skipped) - opt_in
        if unknown_skips:
            raise ValueError(f'unexpected skipped tests: {sorted(unknown_skips)}')
        reported = passed + skipped
        if len(reported) != len(set(reported)) or set(reported) != set(assigned):
            raise ValueError(f'shard {i + first_shard} coverage mismatch: missing={sorted(set(assigned)-set(reported))}, unexpected={sorted(set(reported)-set(assigned))}, duplicates={len(reported)-len(set(reported))}')
        seen.extend(reported)
        counts.append({'number': i + first_shard, 'discovered': len(assigned),
                       'passed': len(passed), 'opt_in_skipped': len(skipped)})
    if len(seen) != len(set(seen)) or set(seen) != set(discovered):
        raise ValueError('overall coverage mismatch')
    return {'discovered': len(discovered), 'passed': sum(c['passed'] for c in counts),
            'opt_in_skipped': sum(c['opt_in_skipped'] for c in counts),
            'shard_count': len(shards), 'shards': counts}


def command(args, logfile, env=None):
    # Keep the driver stderr separate: SwiftPM can otherwise insert a warning
    # in the middle of a test-host line and destroy the coverage evidence.
    errorfile = logfile.with_suffix('.stderr.txt')
    with logfile.open('w') as f, errorfile.open('w') as errors:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=errors, text=True, env=env)
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            f.write(line)
        code = proc.wait()
    with logfile.open('a') as f:
        f.write(errorfile.read_text())
    return code


def failure_evidence(code, log, errorfile):
    # A serial run may still report nested/parameterized test activity. Keep all
    # starts in order and remove completed names instead of assuming the last line.
    events = sorted([(m.start(), True, m.group(1)) for m in STARTED.finditer(log)] +
                    [(m.start(), False, m.group(1)) for m in FINISHED.finditer(log)] +
                    [(m.start(), m.group(3) == 'started', f'{m.group(1)}/{m.group(2)}')
                     for m in XCTEST_EVENT.finditer(log)])
    pending = []
    for _, started, name in events:
        if started:
            pending.append(name)
        elif name in pending:
            pending.remove(name)
    stderr = errorfile.read_text(errors='replace') if errorfile.exists() else ''
    tail = ''.join(stderr.splitlines(keepends=True)[-60:])
    if not tail:
        tail = '(empty)\n'
    return (f'exit code: {code}\nlast started-but-not-finished test: '
            f'{pending[-1] if pending else "none detected"}\n'
            f'stderr tail (up to 60 lines):\n{tail}')


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / 'test-coverage.json').unlink(missing_ok=True)
    # Remove only artifacts from prior shard runs before collecting new evidence.
    (ROOT / 'tests.txt').write_text('')
    for old in ROOT.glob('tests-shard-*.txt'):
        old.unlink()
    # The list command builds the test products with the same strict flags as the old gate.
    listing = ROOT / 'test-discovery.txt'
    err = ROOT / 'test-build.txt'
    with listing.open('w') as out, err.open('w') as errors:
        p = subprocess.run(['swift', 'test', *STRICT, 'list'], stdout=out, stderr=errors)
    print(err.read_text(), end='', flush=True)
    if p.returncode:
        raise ValueError('strict test build/discovery failed')
    tests = discover(listing.read_text())
    shards = partition(tests)
    combined = ROOT / 'tests.txt'
    combined.write_text('')
    results = []
    failures = []
    for i, shard in enumerate(shards, 1):
        # SwiftPM matches the test identifier prefix; the verifier catches any overlap.
        pattern = '|'.join('^' + re.escape(t.split('(')[0]) for t in shard)
        logfile = ROOT / f'tests-shard-{i}.txt'
        print(f'Running shard {i}/{len(shards)} ({len(shard)} discovered definitions)', flush=True)
        code = command(['swift', 'test', '--build-system', 'native', '--skip-build',
                        '--no-parallel', '--filter', pattern], logfile)
        log = logfile.read_text()
        with combined.open('a') as out:
            out.write(f'\n=== Shard {i}/{len(shards)} (exit {code}) ===\n{log}')
        results.append((code, log))
        try:
            check(shard, [shard], [(code, log)], OPT_IN_TESTS & set(shard), first_shard=i)
        except ValueError as exc:
            failures.append(f'shard {i}: {exc}')
            evidence = (f'=== Shard {i} failure evidence ===\n'
                        f'Swift test gate: {failures[-1]}\n'
                        + failure_evidence(code, log, logfile.with_suffix('.stderr.txt'))
                        + f'\n=== End shard {i} failure evidence ===\n')
            (ROOT / f'tests-shard-{i}.failure.txt').write_text(evidence)
            # All live shard output uses stdout, preventing cross-stream reordering.
            print(evidence, end='', flush=True)
    if failures:
        raise ValueError('; '.join(failures))
    summary = check(tests, shards, results)
    (ROOT / 'test-coverage.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as exc:
        print(f'Swift test gate failed: {exc}', file=sys.stderr)
        sys.exit(1)
