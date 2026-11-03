import copy
import json
import os
import tempfile
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import actions_release_guard as guard


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.sha = 'a' * 40
        common = {'head_sha': self.sha, 'head_branch': 'main',
                  'repository': {'full_name': guard.REPO}, 'head_repository': {'full_name': guard.REPO}}
        self.ci = dict(common, id=1, path='.github/workflows/mac-ci-smoke.yml', event='push', status='completed', conclusion='success')
        self.release = dict(common, id=2, path='.github/workflows/production-release.yml', event='workflow_run', status='in_progress')

    def check(self, ci=None, release=None, main=None):
        responses = [{'object': {'sha': main or self.sha}}, ci or self.ci, release or self.release]
        with patch.object(guard, 'api', side_effect=responses):
            return guard.validate(self.sha, '1', '2')

    def test_current_successful_main_is_accepted(self):
        self.assertEqual(self.check(), self.sha)

    def test_stale_main_or_failed_ci_refused(self):
        with self.assertRaises(ValueError): self.check(main='b' * 40)
        ci = dict(self.ci, conclusion='failure')
        with self.assertRaises(ValueError): self.check(ci=ci)

    def test_fork_or_pull_request_refused(self):
        ci = copy.deepcopy(self.ci); ci['head_repository']['full_name'] = 'other/repo'
        with self.assertRaises(ValueError): self.check(ci=ci)
        with self.assertRaises(ValueError): self.check(ci=dict(self.ci, event='pull_request'))

    def test_cancelled_or_wrong_workflow_refused(self):
        with self.assertRaises(ValueError): self.check(release=dict(self.release, status='completed'))
        with self.assertRaises(ValueError): self.check(release=dict(self.release, path='.github/workflows/other.yml'))

    def test_event_file_must_name_exact_trigger_source(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps({'workflow_run': {'id': 1, 'head_sha': self.sha}}))
            env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': guard.REPO,
                   'GITHUB_EVENT_NAME': 'workflow_run', 'GITHUB_EVENT_PATH': str(event), 'GITHUB_RUN_ID': '2'}
            with patch.dict(os.environ, env, clear=True), patch.object(guard, 'validate', return_value=self.sha) as validate:
                self.assertEqual(guard.from_environment(self.sha), self.sha)
                validate.assert_called_once_with(self.sha, '1', '2')
                event.write_text(json.dumps({'workflow_run': {'id': 1, 'head_sha': 'b' * 40}}))
                with self.assertRaises(ValueError): guard.from_environment(self.sha)

    def test_run_id_validation(self):
        for ident in ('0', '-1', '1/../../x', '１２'):
            with self.subTest(ident=ident), self.assertRaises(ValueError): guard.validate(self.sha, ident, '2')


if __name__ == '__main__': unittest.main()
