import json
import hashlib
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
             patch.object(eligibility.subprocess, 'check_output', side_effect=['1.2.3\n', 'b'*40]), \
             patch.object(eligibility.subprocess, 'run'), patch.object(eligibility, 'verify_published'):
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
             patch.object(eligibility.subprocess, 'check_output', side_effect=['1.2.3\n', 'b'*40]), \
             patch.object(eligibility.subprocess, 'run'):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                eligibility.eligible()

    def test_published_assets_must_match_manifest_and_source(self):
        name = 'TinyStats-1.2.3-macOS-universal.zip'
        archive = b'fixture archive'
        digest = hashlib.sha256(archive).hexdigest()
        manifest = {'version': '1.2.3', 'sourceCommit': 'b'*40, 'file': name, 'sha256': digest}
        release = {'assets': [{'name': n} for n in (name, 'release.json', 'SHA256SUMS.txt')]}
        def download(args, **kwargs):
            root = Path(args[args.index('--dir') + 1])
            (root / name).write_bytes(archive)
            (root / 'release.json').write_text(json.dumps(manifest))
            (root / 'SHA256SUMS.txt').write_text(digest + '  ' + name + '\n')
        with patch.object(eligibility.subprocess, 'run', side_effect=download):
            eligibility.verify_published('1.2.3', 'b'*40, release)
            with self.assertRaisesRegex(ValueError, 'tag'):
                eligibility.verify_published('1.2.3', 'c'*40, release)
            manifest['sha256'] = 'd'*64
            with self.assertRaises(ValueError):
                eligibility.verify_published('1.2.3', 'b'*40, release)


if __name__ == '__main__':
    unittest.main()
