import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('shards', ROOT / 'scripts/shard-swift-tests.py')
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)


class SwiftShardsTests(unittest.TestCase):
    def setUp(self):
        self.tests = shards.discover('Core.Suite/testOne\nUI.first()\nUI.second()\n')
        self.opt_in = {'UI.second()'}
        self.parts = shards.partition(self.tests, 2)
        self.logs = [
            (0, "Test Case '-[Core.Suite testOne]' passed (0.1 seconds).\n✔ Test first() passed after 0.1 seconds.\n✔ Test run with 1 test passed"),
            (0, '➜ Test second() skipped.\n✔ Test run with 1 test passed'),
        ]

    def check(self):
        return shards.check(self.tests, self.parts, self.logs, self.opt_in)

    def test_complete(self):
        result = self.check()
        self.assertEqual((result['discovered'], result['passed'], result['opt_in_skipped']), (3, 2, 1))
        self.assertEqual([s['opt_in_skipped'] for s in result['shards']], [0, 1])

    def test_opt_in_can_pass_when_enabled(self):
        self.logs[1] = (0, '✔ Test second() passed after 0.1 seconds.\n✔ Test run with 1 test passed')
        self.assertEqual(self.check()['passed'], 3)

    def test_missing(self):
        self.logs[1] = (0, '✔ Test run with 1 test passed')
        with self.assertRaises(ValueError): self.check()

    def test_duplicate(self):
        self.logs[1] = (0, self.logs[1][1] + '\n➜ Test second() skipped.')
        with self.assertRaises(ValueError): self.check()

    def test_unknown_skip(self):
        self.logs[0] = (0, self.logs[0][1].replace('✔ Test first() passed after 0.1 seconds.', '➜ Test first() skipped.'))
        with self.assertRaises(ValueError): self.check()

    def test_stale_allowlist(self):
        self.opt_in.add('UI.removed()')
        with self.assertRaises(ValueError): self.check()

    def test_no_summary(self):
        self.logs[1] = (0, '➜ Test second() skipped.')
        with self.assertRaises(ValueError): self.check()

    def test_shard_failure(self):
        self.logs[0] = (1, self.logs[0][1])
        with self.assertRaises(ValueError): self.check()

    def test_immediate_check_reports_actual_shard(self):
        with self.assertRaisesRegex(ValueError, 'shard 2 failed'):
            shards.check(self.parts[1], [self.parts[1]], [(1, '')], self.opt_in, first_shard=2)

    def test_main_runs_remaining_shards_and_removes_stale_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'test-coverage.json').write_text('stale pass')
            calls = []

            def discovery(args, stdout, stderr):
                stdout.write('Core.Suite/testOne\nUI.first()\nUI.second()\n')
                return type('Result', (), {'returncode': 0})()

            def run(args, logfile):
                index = len(calls)
                calls.append(logfile)
                code, log = self.logs[index]
                logfile.write_text(log)
                return 1 if index == 0 else code

            with patch.object(shards, 'ROOT', root), patch.object(shards, 'SHARDS', 2), \
                 patch.object(shards, 'partition', side_effect=lambda tests: self.parts), \
                 patch.object(shards, 'OPT_IN_TESTS', self.opt_in), \
                 patch.object(shards.subprocess, 'run', side_effect=discovery), \
                 patch.object(shards, 'command', side_effect=run):
                with self.assertRaisesRegex(ValueError, 'shard 1'):
                    shards.main()
            self.assertEqual(len(calls), 2)
            self.assertFalse((root / 'test-coverage.json').exists())
            self.assertIn('Shard 2/2', (root / 'tests.txt').read_text())

    def test_empty_discovery(self):
        with self.assertRaises(ValueError): shards.discover('')

    def test_ambiguous_names(self):
        with self.assertRaises(ValueError): shards.discover('A.same()\nB.same()\n')

    def test_empty_swift_shard(self):
        with self.assertRaises(ValueError): shards.partition(['A.first()'], 2)

    def test_skip_traits_match_documented_allowlist(self):
        # Every conditional/disabled trait must have a corresponding documented test.
        # Count traits as well as names so duplicate traits cannot disappear in a set.
        traits = []
        for path in (ROOT / 'Tests').rglob('*.swift'):
            source = path.read_text()
            for trait in re.finditer(r'\.(?:enabled\s*\(\s*if\s*:|disabled\s*\()', source):
                following = source[trait.end():]
                match = re.search(r'\bfunc\s+(\w+)\s*\(', following)
                self.assertIsNotNone(match, f'{path}: trait without a following test function')
                traits.append(match.group(1) + '()')
        expected = [t.rsplit('/', 1)[-1].rsplit('.', 1)[-1] for t in shards.OPT_IN_TESTS]
        self.assertCountEqual(traits, expected)
