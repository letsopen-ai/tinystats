import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class HostedEvidenceTests(unittest.TestCase):
    def test_collect_preserves_logs_and_tolerates_no_reports(self):
        source = Path(__file__).resolve().parents[1] / 'hosted-test-evidence.sh'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'build/ci').mkdir(parents=True)
            shutil.copy(source, root / 'scripts/hosted-test-evidence.sh')
            (root / 'build/ci/test-start').touch()
            (root / 'build/ci/tests.txt').write_text('unfinished test\n')
            (root / 'build/ci/test-resources.txt').write_text('sample marker\n')
            summary = root / 'summary'
            env = dict(os.environ, HOME=str(root), GITHUB_STEP_SUMMARY=str(summary))
            result = subprocess.run(
                ['bash', str(root / 'scripts/hosted-test-evidence.sh'), 'collect', '1'],
                cwd=root, env=env, text=True, capture_output=True, check=True)
            for marker in ('Test command status: 1', 'sample marker', 'unfinished test',
                           'New DiagnosticReports'):
                self.assertIn(marker, result.stdout)
                self.assertIn(marker, summary.read_text())


if __name__ == '__main__':
    unittest.main()
