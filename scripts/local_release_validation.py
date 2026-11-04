#!/usr/bin/env python3
"""Bind maintainer-run local validation to committed native release inputs.

This is a source-integrity check of a maintainer's recorded test result, not a
remote attestation or proof of runtime support on another host/OS.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone

APP = 'tinystats'
ROOT = Path(__file__).resolve().parents[1]
RECEIPT = 'docs/validation/local-release-validation.json'
INPUTS = ('Sources', 'Tests', 'Resources', 'native', 'apps', 'scripts', '.github',
          'data', 'design/icon', 'Package.swift', 'Package.resolved', 'VERSION',
          'AGENTS.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
RECIPE = APP + '-local-native-release-v1'


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL)


def clean_inputs(root):
    result = subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', *INPUTS], cwd=root)
    if result.returncode or git(root, 'ls-files', '--others', '--exclude-standard', '--', *INPUTS).strip():
        raise RuntimeError('Commit native release input changes before local validation')


def fingerprint(root):
    return hashlib.sha256(git(root, 'ls-tree', '-r', '-z', 'HEAD', '--', *INPUTS)).hexdigest()


def version(root):
    value = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise RuntimeError('Invalid release version')
    return value


def verify(root=ROOT, allow_published=False):
    clean_inputs(root)
    current = version(root)
    if allow_published:
        tag = 'refs/tags/v' + current
        exists = subprocess.run(['git', 'rev-parse', '--verify', '--quiet', tag], cwd=root, stdout=subprocess.DEVNULL)
        if exists.returncode == 0:
            if (git(root, 'show', tag + ':VERSION').decode().strip() != current
                    or subprocess.run(['git', 'merge-base', '--is-ancestor', tag, 'HEAD'], cwd=root).returncode):
                raise RuntimeError('Published tag version mismatch')
            print('Version already tagged; no new signing authorized by this metadata check.')
            return
    path = root / RECEIPT
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16384:
        raise RuntimeError('Missing local release validation receipt')
    try:
        git(root, 'ls-files', '--error-unmatch', '--', RECEIPT)
        if subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', RECEIPT], cwd=root).returncode:
            raise RuntimeError('Commit the local validation receipt before release')
        receipt = json.loads(path.read_text())
    except (ValueError, subprocess.CalledProcessError):
        raise RuntimeError('Invalid or uncommitted local validation receipt') from None
    if (not isinstance(receipt, dict) or not isinstance(receipt.get('host'), dict)
            or receipt.get('schema') != 1 or receipt.get('result') != 'passed'
            or receipt.get('recipe') != RECIPE or receipt.get('version') != current
            or receipt.get('inputsSHA256') != fingerprint(root)
            or receipt.get('host', {}).get('system') != 'Darwin'):
        raise RuntimeError('Local validation does not match these native release inputs')
    print('Recorded local validation matches the committed native release inputs; no tests ran in CI.')


def record(root=ROOT):
    if platform.system() != 'Darwin' or os.environ.get('GITHUB_ACTIONS') == 'true':
        raise RuntimeError('Record native validation locally on a Mac, outside GitHub Actions')
    clean_inputs(root)
    before = fingerprint(root)
    if APP == 'tinystats':
        commands = [('complete-local-gate', ['bash', 'scripts/verify-local.sh'])]
    else:
        commands = [
            ('release-regressions', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-p', 'test*release*py']),
            ('native-executable', ['swift', 'build', '--product', 'TeleframeMac', '--jobs', '4']),
            ('native-core-tests', ['swift', 'test', '--jobs', '4', '--no-parallel', '--filter', 'TeleframeCoreTests']),
        ]
    logs = root / 'build/local-release-validation'
    logs.mkdir(parents=True, mode=0o700, exist_ok=True)
    for label, command in commands:
        print('Local validation: ' + label, flush=True)
        path = logs / (label + '.log')
        with path.open('w') as output:
            path.chmod(0o600)
            result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(label + ' failed; inspect build/local-release-validation locally')
        text = path.read_text(errors='replace')
        if label == 'native-core-tests' and not re.search(r'Test run with [1-9][0-9]* tests?(?: in [0-9]+ suites?)? passed', text):
            raise RuntimeError('Native tests did not report a completed nonempty pass')
        if label == 'release-regressions' and not re.search(r'Ran [1-9][0-9]* tests?', text):
            raise RuntimeError('Release regression discovery was empty')
    clean_inputs(root)
    if fingerprint(root) != before:
        raise RuntimeError('Native release inputs changed during local validation')
    receipt = {'schema': 1, 'recipe': RECIPE, 'result': 'passed', 'version': version(root),
               'inputsSHA256': before, 'testedCommit': git(root, 'rev-parse', 'HEAD').decode().strip(),
               'completedAt': datetime.now(timezone.utc).isoformat(),
               'host': {'system': platform.system(), 'architecture': platform.machine()},
               'checks': [label for label, _ in commands]}
    path = root / RECEIPT
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print('Local validation passed. Commit ' + RECEIPT + ' with the release change.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('record', 'check'))
    parser.add_argument('--allow-published', action='store_true')
    args = parser.parse_args()
    try:
        record() if args.action == 'record' else verify(allow_published=args.allow_published)
    except (RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from None
