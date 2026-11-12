import tempfile
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from notary_config import keychain_arguments


class NotaryConfigurationTests(unittest.TestCase):
    def test_no_override_retains_existing_profile_behavior(self):
        self.assertEqual(keychain_arguments({}), [])

    def test_requires_private_regular_keychain(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'keychain-db'; p.write_bytes(b'fixture'); p.chmod(0o644)
            env = {'TINYSTATS_NOTARY_KEYCHAIN': str(p)}
            with self.assertRaises(ValueError): keychain_arguments(env)
            p.chmod(0o600)
            self.assertEqual(keychain_arguments(env), ['--keychain', str(p)])
            q = Path(directory) / 'link'; q.symlink_to(p)
            with self.assertRaises(ValueError): keychain_arguments({'TINYSTATS_NOTARY_KEYCHAIN': str(q)})


if __name__ == '__main__': unittest.main()
