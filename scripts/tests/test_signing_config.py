import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from signing_config import identity_keychain_arguments, codesign_keychain_arguments, verify_certificate_team
from types import SimpleNamespace


class ScopedSigningTests(unittest.TestCase):
    def test_explicit_keychain_selects_identity_and_codesigning(self):
        self.assertEqual(identity_keychain_arguments({}), [])
        self.assertEqual(codesign_keychain_arguments({}), [])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'signing keychain-db'; path.write_bytes(b'fixture'); path.chmod(0o600)
            env = {'TINYSTATS_SIGNING_KEYCHAIN': str(path)}
            self.assertEqual(identity_keychain_arguments(env), [str(path)])
            self.assertEqual(codesign_keychain_arguments(env), ['--keychain', str(path)])
            with patch('signing_config.os.getuid', return_value=os.getuid() + 1):
                with self.assertRaises(ValueError): identity_keychain_arguments(env)
            path.chmod(0o644)
            with self.assertRaises(ValueError): codesign_keychain_arguments(env)
            path.chmod(0o600)
            link = Path(directory) / 'link'; link.symlink_to(path)
            with self.assertRaises(ValueError):
                identity_keychain_arguments({'TINYSTATS_SIGNING_KEYCHAIN': str(link)})
            path.unlink()
            with self.assertRaises(ValueError): identity_keychain_arguments(env)

    def test_certificate_sha1_is_bound_to_subject_ou(self):
        pem = '-----BEGIN CERTIFICATE-----fixture-----END CERTIFICATE-----'
        fingerprint = 'AB' * 20
        for digest, units, accepted in ((fingerprint, ['ABCDEFGHIJ'], True),
                                        ('CD' * 20, ['ABCDEFGHIJ'], False),
                                        (fingerprint, ['OTHERTEAM1'], False),
                                        (fingerprint, [], False),
                                        (fingerprint, ['ABCDEFGHIJ', 'OTHERTEAM1'], False)):
            details = 'SHA1 Fingerprint=' + ':'.join(digest[i:i+2] for i in range(0, 40, 2)) + '\nsubject=\n'
            details += ''.join('    OU=' + unit + '\n' for unit in units)
            with self.subTest(digest=digest, units=units), patch('signing_config.subprocess.run', side_effect=[
                    SimpleNamespace(stdout=pem), SimpleNamespace(stdout=details)]) as run:
                if accepted: verify_certificate_team({}, fingerprint.lower(), 'ABCDEFGHIJ')
                else:
                    with self.assertRaises(RuntimeError): verify_certificate_team({}, fingerprint, 'ABCDEFGHIJ')
                self.assertEqual(run.call_args.kwargs['input'], pem)


if __name__ == '__main__': unittest.main()
