import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner_release_eligibility as eligibility


class EligibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'VERSION').write_text('1.2.3\n')
        self.event = self.root / 'event.json'
        self.event.write_text(json.dumps({'workflow_run': {'head_sha': 'a' * 40}}))
        self.env = patch.dict('os.environ', {'GITHUB_EVENT_PATH': str(self.event)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_only_exact_existing_tag_skips(self):
        with patch.object(eligibility, 'ROOT', self.root), \
             patch.object(eligibility, 'from_environment') as guard, \
             patch.object(eligibility, 'api', side_effect=[
                 [{'ref': 'refs/tags/v1.2.30'}], [{'ref': 'refs/tags/v1.2.3'}],
                 {'draft': False, 'prerelease': False, 'assets': [{'name': 'fixture'}]}]) as api, \
             patch.object(eligibility.subprocess, 'check_output', return_value='1.2.3\n'), \
             patch.object(eligibility.subprocess, 'run'):
            self.assertTrue(eligibility.eligible())
            guard.assert_called_once_with('a' * 40)
            self.assertFalse(eligibility.eligible())

    def test_guard_failure_never_queries_tag(self):
        with patch.object(eligibility, 'from_environment', side_effect=ValueError('invalid')), \
             patch.object(eligibility, 'api') as api:
            with self.assertRaisesRegex(ValueError, 'invalid'):
                eligibility.eligible()
            api.assert_not_called()

    def test_existing_draft_is_not_a_successful_skip(self):
        with patch.object(eligibility, 'ROOT', self.root), patch.object(eligibility, 'from_environment'), \
             patch.object(eligibility, 'api', side_effect=[
                 [{'ref': 'refs/tags/v1.2.3'}], {'draft': True, 'assets': [{'name': 'fixture'}]}]), \
             patch.object(eligibility.subprocess, 'check_output', return_value='1.2.3\n'), \
             patch.object(eligibility.subprocess, 'run'):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                eligibility.eligible()


if __name__ == '__main__':
    unittest.main()
