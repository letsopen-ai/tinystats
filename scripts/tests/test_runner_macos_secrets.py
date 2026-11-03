import base64
from pathlib import Path
import tempfile
import unittest
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runner_macos_secrets import materialize


class MacSecretTests(unittest.TestCase):
    def setUp(self):
        self.values = {'MACOS_CERTIFICATE_P12_BASE64':base64.b64encode(b'fixture').decode(),
            'MACOS_CERTIFICATE_PASSWORD':'fixture', 'APPLE_NOTARY_API_KEY_P8':'fixture PRIVATE KEY',
            'APPLE_NOTARY_KEY_ID':'fixture', 'APPLE_NOTARY_ISSUER_ID':'fixture'}

    def test_private_files_are_cleaned_on_exception(self):
        with tempfile.TemporaryDirectory() as parent:
            with self.assertRaisesRegex(RuntimeError, 'fixture'):
                with materialize(self.values, parent) as root:
                    self.assertEqual(root.stat().st_mode & 0o777, 0o700)
                    self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in root.iterdir()))
                    raise RuntimeError('fixture')
            self.assertFalse(root.exists())

    def test_missing_or_invalid_input_leaves_no_files(self):
        with tempfile.TemporaryDirectory() as parent:
            for key, value in [('MACOS_CERTIFICATE_PASSWORD',''), ('MACOS_CERTIFICATE_P12_BASE64','bad*')]:
                with self.assertRaises(ValueError):
                    with materialize(dict(self.values, **{key:value}), parent): pass
                self.assertEqual(list(Path(parent).iterdir()), [])


if __name__ == '__main__': unittest.main()
