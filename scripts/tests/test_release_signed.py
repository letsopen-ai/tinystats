"""Production publication rejection tests. No Apple credentials or network used."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_signed', Path(__file__).resolve().parents[1] / 'release_signed.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class SignedReleaseTests(unittest.TestCase):
    def test_notarization_requires_accepted_status_and_submission_id(self):
        self.assertEqual(release.check_notary('{"status":"Accepted","id":"test-id"}'), 'test-id')
        for data in ({'status': 'Rejected', 'id': 'x'}, {'status': 'In Progress', 'id': 'x'}, {'status': 'Accepted'}):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                release.check_notary(json.dumps(data))

    def test_version_and_production_identity_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'Resources').mkdir()
            (root / 'VERSION').write_text('0.36.4\n')
            info = {'CFBundleShortVersionString': '0.36.4', 'CFBundleVersion': '67', 'CFBundleIdentifier': 'com.niechen.tinystats'}
            p = root / 'Resources/Info.plist'; p.write_bytes(plistlib.dumps(info))
            with patch.object(release, 'ROOT', root):
                self.assertEqual(release.version_metadata(), ('0.36.4', '67'))
                for field, value in [('CFBundleShortVersionString', '0.36.3'), ('CFBundleIdentifier', 'example.fixture')]:
                    bad = dict(info); bad[field] = value; p.write_bytes(plistlib.dumps(bad))
                    with self.assertRaises(RuntimeError): release.version_metadata()

    def test_existing_release_or_tag_cannot_be_replaced(self):
        for releases, refs in [([{'tag_name': 'v0.36.4'}], []), ([], [{'ref': 'refs/tags/v0.36.4'}])]:
            with patch.object(release, 'api', side_effect=[releases, refs]), self.assertRaises(RuntimeError):
                release.assert_unpublished('0.36.4')

    def test_tag_changed_while_draft_is_pending_cannot_publish(self):
        original = 'a' * 40
        moved = 'b' * 40
        # A version tag may be annotated; peel it before comparing source identity.
        with patch.object(release, 'api', side_effect=[
                {'object': {'type': 'tag', 'sha': 'c' * 40}},
                {'object': {'type': 'commit', 'sha': original}}]):
            release.verify_release_tag('0.36.4', original)
        with patch.object(release, 'api', return_value={'object': {'type': 'commit', 'sha': moved}}), self.assertRaisesRegex(RuntimeError, 'verified source'):
            release.verify_release_tag('0.36.4', original)

    def test_cancelled_request_cannot_publish(self):
        deployment = {'sha': 'a' * 40, 'environment': 'production', 'task': 'release-signed', 'payload': {'release_run_id': 12}}
        with patch.object(release, 'api', side_effect=[deployment, [{'state': 'error'}]]), self.assertRaises(RuntimeError):
            release.request_active(7, 'a' * 40)
        with patch.object(release, 'api', side_effect=[deployment, [{'state': 'in_progress'}], {'status': 'completed'}]), self.assertRaises(RuntimeError):
            release.request_active(7, 'a' * 40)


if __name__ == '__main__':
    unittest.main()
