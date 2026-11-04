import contextlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner_release_exec as runner


class DirectReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name); event = self.home / 'event.json'
        event.write_text(json.dumps({'workflow_run': {'head_sha':'a'*40}}))
        self.root = self.home / 'private'; self.root.mkdir()
        self.env = {'HOME': str(self.home), 'GITHUB_EVENT_PATH': str(event), 'GH_TOKEN':'fixture',
            'APPLE_TEAM_ID':'ABCDEFGHIJ', 'MACOS_CERTIFICATE_FINGERPRINT':'a'*40,
            'MACOS_CERTIFICATE_PASSWORD':'fixture-password', 'MACOS_CERTIFICATE_P12_BASE64':'fixture-cert',
            'APPLE_NOTARY_API_KEY_P8':'fixture-key', 'APPLE_NOTARY_KEY_ID':'ABCDEFGHIJ',
            'APPLE_NOTARY_ISSUER_ID':'fixture-issuer'}
        self.identity = types.SimpleNamespace(pw_name='release-runner', pw_dir=str(self.home))

    def test_direct_release_reduces_secrets_and_orders_notary_first(self):
        events = []
        with patch.dict(runner.os.environ, {'MACOS_CERTIFICATE_PASSWORD':'fixture-password'}), \
             patch.object(runner.pwd, 'getpwuid', return_value=self.identity), patch.object(runner.os, 'geteuid', return_value=501), \
             patch.object(runner, 'from_environment'), patch('release_signed.source_commit', return_value='a'*40), \
             patch('release_signed.verify_ci_validation'), patch.object(runner, 'release_lock', return_value=contextlib.nullcontext()), \
             patch.object(runner, 'materialize', return_value=contextlib.nullcontext(self.root)), \
             patch.object(runner, 'signing_keychain', return_value=contextlib.nullcontext(self.root / 'keychain')), \
             patch.object(runner, 'command', side_effect=lambda *a,**k: events.append((a,k))):
            runner.run(self.env)
            self.assertNotIn('MACOS_CERTIFICATE_PASSWORD', runner.os.environ)
        self.assertEqual(len(events),2)
        self.assertIn('store-credentials', events[0][0][0])
        self.assertIn('--actions-direct', events[1][0][0])
        for _,kwargs in events:
            self.assertNotIn('MACOS_CERTIFICATE_PASSWORD', kwargs['env'])
            self.assertNotIn('APPLE_NOTARY_API_KEY_P8', kwargs['env'])
        self.assertNotIn('fixture-password', str(events[0][0][0]))

    def test_existing_staging_blocks_secret_access(self):
        parent=self.home/'Library/Caches/MacCIReleaseSecrets'; parent.mkdir(parents=True, mode=0o700); (parent/'stale').touch()
        with patch.object(runner.pwd, 'getpwuid', return_value=self.identity), patch.object(runner.os, 'geteuid', return_value=501), \
             patch.object(runner, 'from_environment'), patch('release_signed.source_commit', return_value='a'*40), \
             patch('release_signed.verify_ci_validation'), patch.object(runner, 'release_lock', return_value=contextlib.nullcontext()), \
             patch.object(runner, 'materialize') as staging:
            with self.assertRaisesRegex(RuntimeError, 'Previous release staging'): runner.run(self.env)
            staging.assert_not_called()

    def test_wrong_account_is_rejected_before_staging(self):
        wrong=types.SimpleNamespace(pw_name='runner', pw_dir=str(self.home))
        with patch.object(runner.pwd, 'getpwuid', return_value=wrong), patch.object(runner.os, 'geteuid', return_value=501), \
             patch.object(runner, 'materialize') as staging:
            with self.assertRaises(ValueError): runner.run(self.env)
            staging.assert_not_called()


if __name__ == '__main__': unittest.main()
