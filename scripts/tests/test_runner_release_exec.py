import contextlib
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner_release_exec as runner


class DirectReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.parent = Path(self.tmp.name).resolve(); event = self.parent / 'event.json'
        event.write_text(json.dumps({'workflow_run': {'head_sha': 'a'*40}}))
        self.root = self.parent / 'tinystats-signing'
        self.env = {'RUNNER_TEMP': str(self.parent), 'GITHUB_ACTIONS': 'true',
            'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_EVENT_PATH': str(event), 'GH_TOKEN': 'fixture',
            'APPLE_TEAM_ID': 'ABCDEFGHIJ', 'MACOS_CERTIFICATE_FINGERPRINT': 'a'*40,
            'MACOS_CERTIFICATE_PASSWORD': 'fixture-password',
            'MACOS_CERTIFICATE_P12_BASE64': base64.b64encode(b'fixture-cert').decode(),
            'APPLE_NOTARY_API_KEY_P8': 'fixture PRIVATE KEY', 'APPLE_NOTARY_KEY_ID': 'ABCDEFGHIJ',
            'APPLE_NOTARY_ISSUER_ID': 'fixture-issuer'}
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(runner.os, 'geteuid', return_value=501))
        self.guard = self.stack.enter_context(patch.object(runner, 'from_environment'))
        self.source = self.stack.enter_context(patch('release_signed.source_commit', return_value='a'*40))
        self.validation = self.stack.enter_context(patch('release_signed.verify_ci_validation'))
        self.keychain_exits = []
        @contextlib.contextmanager
        def keychain(root, certificate, password):
            self.assertEqual(root, self.root)
            self.assertEqual(certificate.stat().st_mode & 0o777, 0o600)
            try:
                yield root / 'release-signing.keychain-db'
            finally:
                self.keychain_exits.append(True)
        self.keychain = self.stack.enter_context(patch.object(runner, 'signing_keychain', side_effect=keychain))
        self.command = self.stack.enter_context(patch.object(runner, 'command'))

    def test_direct_release_reduces_secrets_and_orders_notary_first(self):
        with patch.dict(runner.os.environ, self.env):
            runner.run(self.env)
            for name in runner.SECRET_NAMES:
                self.assertNotIn(name, runner.os.environ)
        events = self.command.call_args_list
        self.assertEqual(len(events), 2)
        self.assertIn('store-credentials', events[0].args[0])
        self.assertIn('--actions-direct', events[1].args[0])
        for event in events:
            for name in runner.SECRET_NAMES:
                self.assertNotIn(name, event.kwargs['env'])
        self.assertNotIn('fixture-password', str(events))
        self.assertFalse(self.root.exists())
        self.assertEqual(self.keychain_exits, [True])
        self.assertEqual(self.guard.call_count, 2)
        self.validation.assert_called_once_with('a'*40)

    def test_existing_staging_blocks_secret_access(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink: self.root.symlink_to(self.parent, target_is_directory=True)
                else: self.root.mkdir(mode=0o700)
                with self.assertRaisesRegex(RuntimeError, 'already exists'): runner.run(self.env)
                self.keychain.assert_not_called()
                if symlink: self.root.unlink()
                else: self.root.rmdir()

    def test_requires_hosted_actions_non_root_and_owned_temp(self):
        for change in ({'RUNNER_ENVIRONMENT': 'self-hosted'}, {'RUNNER_ENVIRONMENT': ''},
                       {'GITHUB_ACTIONS': 'false'}, {'RUNNER_TEMP': ''}, {'RUNNER_TEMP': 'relative'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.run(dict(self.env, **change))
        with patch.object(runner.os, 'geteuid', return_value=0), self.assertRaises(ValueError):
            runner.run(self.env)
        with patch('runner_macos_secrets.os.getuid', return_value=os.getuid()+1), self.assertRaises(ValueError):
            runner.run(self.env)
        link = self.parent / 'link'; link.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises(ValueError): runner.run(dict(self.env, RUNNER_TEMP=str(link)))
        self.keychain.assert_not_called()
        self.command.assert_not_called()

    def test_cleanup_runs_on_notary_and_release_failure(self):
        for failure in (0, 1):
            with self.subTest(failure=failure):
                self.command.side_effect = ([RuntimeError('fixture failure')] if failure == 0
                                            else [None, RuntimeError('fixture failure')])
                with self.assertRaisesRegex(RuntimeError, 'fixture failure'): runner.run(self.env)
                self.assertFalse(self.root.exists())
        self.assertEqual(self.keychain_exits, [True, True])

    def test_guards_precede_secret_staging(self):
        for check in (self.guard, self.source, self.validation):
            with self.subTest(check=check):
                check.side_effect = ValueError('untrusted')
                with self.assertRaisesRegex(ValueError, 'untrusted'): runner.run(self.env)
                self.keychain.assert_not_called()
                self.assertFalse(self.root.exists())
                check.side_effect = None
        self.source.return_value = 'b'*40
        with self.assertRaisesRegex(ValueError, 'differs'): runner.run(self.env)
        self.keychain.assert_not_called()


if __name__ == '__main__': unittest.main()
