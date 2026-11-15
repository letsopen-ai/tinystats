from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner_keychain as keychain


class FakeSecurity:
    def __init__(self, fail=None):
        self.search = ['/fixture/login.keychain-db']
        self.events = []
        self.calls = []
        self.fail = fail

    def __call__(self, *args):
        self.events.append(args[0])
        self.calls.append(args)
        if args[0] == self.fail:
            raise RuntimeError('fixture failure')
        if args[0] == 'create-keychain':
            Path(args[-1]).touch(mode=0o600)
        if args[:3] == ('list-keychains', '-d', 'user'):
            if len(args) == 3:
                return ''.join('"' + str(x) + '"\n' for x in self.search)
            self.search = list(map(str, args[4:]))
        return ''


class KeychainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.root.chmod(0o700)
        self.cert = self.root / 'fixture.p12'; self.cert.write_bytes(b'fixture'); self.cert.chmod(0o600)

    def test_temporary_keychain_is_detached_and_deleted(self):
        fake = FakeSecurity()
        with patch.object(keychain, '_security', side_effect=fake), patch.object(keychain, '_security_private', side_effect=fake), patch.object(keychain.os, 'geteuid', return_value=501):
            with keychain.signing_keychain(self.root, self.cert, 'fixture') as path:
                self.assertEqual(fake.search[0], str(path))
                fake.search.append('/fixture/another.keychain-db')
        self.assertEqual(fake.search, ['/fixture/login.keychain-db', '/fixture/another.keychain-db'])
        self.assertEqual(fake.events[-1], 'delete-keychain')
        settings = next(call for call in fake.calls if call[0] == 'set-keychain-settings')
        self.assertEqual(settings[1:3], ('-lut', '10800'))

    def test_empty_search_list_preserves_initial_fallback_or_skips_update(self):
        for initial in ([], ['/fixture/login.keychain-db']):
            with self.subTest(initial=initial):
                fake = FakeSecurity(); fake.search = initial.copy()
                with patch.object(keychain, '_security', side_effect=fake), \
                     patch.object(keychain, '_security_private', side_effect=fake), \
                     patch.object(keychain.os, 'geteuid', return_value=501):
                    with keychain.signing_keychain(self.root, self.cert, 'fixture') as path:
                        fake.search = [str(path)]
                updates = [call for call in fake.calls if call[:4] == ('list-keychains', '-d', 'user', '-s')]
                self.assertTrue(all(len(call) > 4 for call in updates))
                self.assertEqual(len(updates), 1 + bool(initial))
                if initial:
                    self.assertEqual(fake.search, initial)
                self.assertEqual(fake.events[-1], 'delete-keychain')
                path.unlink()  # The fake deletion leaves its placeholder file.

    def test_import_failure_deletes_created_keychain(self):
        fake = FakeSecurity(fail='import')
        with patch.object(keychain, '_security', side_effect=fake), patch.object(keychain, '_security_private', side_effect=fake), patch.object(keychain.os, 'geteuid', return_value=501):
            with self.assertRaises(RuntimeError):
                with keychain.signing_keychain(self.root, self.cert, 'fixture'): pass
        self.assertEqual(fake.events[-1], 'delete-keychain')
        self.assertEqual(fake.search, ['/fixture/login.keychain-db'])

    def test_sensitive_password_is_sent_on_stdin_not_process_arguments(self):
        class Result:
            returncode = 0
            stdout = ''
        with patch.object(keychain.subprocess, 'run', return_value=Result()) as call:
            keychain._security_private('import', self.cert, '-P', 'fixture $ password')
        args, kwargs = call.call_args
        self.assertEqual(args[0], ['/usr/bin/security', '-i'])
        self.assertNotIn('fixture $ password', str(args))
        self.assertIn('fixture $ password', kwargs['input'])
        with self.assertRaises(ValueError): keychain._security_private('import', '-P', 'fixture\npassword')

    def test_uncertain_search_list_update_is_reconciled(self):
        fake = FakeSecurity()
        failed = False
        def partial(*args):
            nonlocal failed
            if args[:4] == ('list-keychains', '-d', 'user', '-s') and not failed:
                fake.search = list(map(str, args[4:]))
                failed = True
                raise RuntimeError('fixture unknown outcome')
            return fake(*args)
        with patch.object(keychain, '_security', side_effect=partial), \
             patch.object(keychain, '_security_private', side_effect=fake), \
             patch.object(keychain.os, 'geteuid', return_value=501):
            with self.assertRaisesRegex(RuntimeError, 'unknown outcome'):
                with keychain.signing_keychain(self.root, self.cert, 'fixture'): pass
        self.assertEqual(fake.search, ['/fixture/login.keychain-db'])
        self.assertEqual(fake.events[-1], 'delete-keychain')

    def test_refuses_non_private_certificate_before_any_security_action(self):
        self.cert.chmod(0o644)
        with patch.object(keychain, '_security') as call, patch.object(keychain.os, 'geteuid', return_value=501):
            with self.assertRaises(ValueError):
                with keychain.signing_keychain(self.root, self.cert, 'fixture'): pass
        call.assert_not_called()


if __name__ == '__main__': unittest.main()
