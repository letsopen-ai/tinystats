"""Exercise the actual shell completion gate, not a duplicated parser."""
import pathlib
import subprocess
import tempfile
import unittest

GATE = pathlib.Path(__file__).resolve().parents[1] / 'verify-swift-tests.sh'


class SwiftTestCompletionTests(unittest.TestCase):
    def run_gate(self, output):
        with tempfile.TemporaryDirectory(prefix='tinystats-test-summary-') as directory:
            log = pathlib.Path(directory) / 'Swift test log.txt'
            log.write_text(output)
            return subprocess.run(
                ['/bin/bash', str(GATE), str(log)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            ).returncode

    def test_actual_zero_and_one_suite_and_legacy_summaries_pass(self):
        for output in [
            '✔ Test run with 382 tests in 0 suites passed after 14.152 seconds.\n',
            '✔ Test run with 384 tests in 1 suite passed after 22.116 seconds.\n',
            '✔ Test run with 384 tests in 2 suites passed after 22.116 seconds.\n',
            '✔ Test run with 1 test in 1 suite passed after 0.01 seconds.\n',
            '✔ Test run with 1 test passed after 0.01 seconds.\n',
        ]:
            with self.subTest(output=output):
                self.assertEqual(self.run_gate(output), 0)

    def test_xctest_only_does_not_hide_stopped_swift_testing(self):
        output = "Test Suite 'All tests' passed\nExecuted 56 tests, with 0 failures\n"
        self.assertNotEqual(self.run_gate(output), 0)
        self.assertNotEqual(self.run_gate(output + '◇ Test run started.\n'), 0)

    def test_empty_and_failed_or_incomplete_runs_are_rejected(self):
        for output in [
            '',
            '✔ Suite HistoryCheckpointReadingTests passed after 22 seconds.\n',
            '✘ Test run with 384 tests in 1 suite failed with 1 issue.\n',
            'Test run with 0 tests in 0 suites passed after 0 seconds.\n',
            'Test run with 384 tests in 1 suite',
            'Test run with 384 tests in 1 suite started.\n',
        ]:
            with self.subTest(output=output):
                self.assertNotEqual(self.run_gate(output), 0)

    def test_missing_log_is_a_failure(self):
        with tempfile.TemporaryDirectory(prefix='tinystats-test-summary-') as directory:
            result = subprocess.run(
                ['/bin/bash', str(GATE), str(pathlib.Path(directory) / 'missing')],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
