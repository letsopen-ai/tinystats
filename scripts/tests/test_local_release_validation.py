"""Exercise the release source gate with real temporary Git histories."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import local_release_validation as validation

class LocalReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q'); self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.root / 'VERSION').write_text('1.0.0\n')
        (self.root / 'Sources').mkdir(); (self.root / 'Sources/input.swift').write_text('fixture')
        self.commit()
        self.receipt = {'schema': 1, 'recipe': validation.RECIPE, 'result': 'passed',
                        'host': {'system': 'Darwin'}, 'version': '1.0.0',
                        'inputsSHA256': validation.fingerprint(self.root)}
        self.save_receipt()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.DEVNULL)

    def commit(self):
        self.git('add', '.'); self.git('commit', '-qm', 'fixture')

    def save_receipt(self):
        p = self.root / validation.RECEIPT; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(self.receipt)); self.commit()

    def test_committed_receipt_survives_doc_only_commit_but_not_source_change(self):
        validation.verify(self.root)
        (self.root / 'README.md').write_text('documentation'); self.commit()
        validation.verify(self.root)
        (self.root / 'Sources/input.swift').write_text('changed'); self.commit()
        with self.assertRaisesRegex(RuntimeError, 'does not match'): validation.verify(self.root)

    def test_dirty_source_and_uncommitted_receipt_are_rejected(self):
        p = self.root / 'Sources/untracked.swift'; p.write_text('untracked')
        with self.assertRaisesRegex(RuntimeError, 'Commit native'): validation.verify(self.root)
        p.unlink()
        (self.root / validation.RECEIPT).write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'Commit the local'): validation.verify(self.root)

    def test_malformed_or_foreign_receipt_cannot_authorize_signing(self):
        for value in ([], dict(self.receipt, host=[]), dict(self.receipt, recipe='other'),
                      dict(self.receipt, version='1.0.1'), dict(self.receipt, result='failed')):
            p = self.root / validation.RECEIPT; p.write_text(json.dumps(value)); self.commit()
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, 'does not match'):
                validation.verify(self.root)

    def test_tag_skip_is_only_metadata_and_never_authorizes_release(self):
        self.git('tag', 'v1.0.0')
        (self.root / 'Sources/input.swift').write_text('new changes'); self.commit()
        validation.verify(self.root, allow_published=True)
        with self.assertRaisesRegex(RuntimeError, 'does not match'): validation.verify(self.root)

    def test_record_refuses_actions_before_running_commands(self):
        with patch.dict(validation.os.environ, {'GITHUB_ACTIONS': 'true'}), \
             patch.object(validation.platform, 'system', return_value='Darwin'), \
             patch.object(validation, 'clean_inputs') as clean:
            with self.assertRaisesRegex(RuntimeError, 'outside GitHub'): validation.record(self.root)
            clean.assert_not_called()

if __name__ == '__main__': unittest.main()
