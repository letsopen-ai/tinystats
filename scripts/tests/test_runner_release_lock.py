import tempfile
from pathlib import Path
import sys
import subprocess
import time
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runner_release_lock import release_lock


class ReleaseLockTests(unittest.TestCase):
    def test_waiting_job_acquires_lock_after_other_process_finishes(self):
        with tempfile.TemporaryDirectory() as home:
            code = ('import sys; sys.path.insert(0, sys.argv[1]); '
                    'from runner_release_lock import release_lock; '
                    'cm=release_lock(sys.argv[2], wait_seconds=1); cm.__enter__(); print("acquired", flush=True)')
            with release_lock(home):
                process = subprocess.Popen([sys.executable, '-c', code,
                                            str(Path(__file__).resolve().parents[1]), home],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                time.sleep(0.1)
                self.assertIsNone(process.poll())
            out, err = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 0, err)
            self.assertIn(b'acquired', out)

    def test_concurrent_job_refused_then_lock_can_be_reused(self):
        with tempfile.TemporaryDirectory() as home:
            with release_lock(home):
                with self.assertRaisesRegex(RuntimeError, 'Another release'):
                    with release_lock(home): pass
            with release_lock(home): pass

    def test_another_process_cannot_acquire_the_same_lock(self):
        with tempfile.TemporaryDirectory() as home:
            code = ('import sys; sys.path.insert(0, sys.argv[1]); '
                    'from runner_release_lock import release_lock; '
                    'cm=release_lock(sys.argv[2]); cm.__enter__()')
            with release_lock(home):
                result = subprocess.run([sys.executable, '-c', code,
                                         str(Path(__file__).resolve().parents[1]), home], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Another release job', result.stderr)

    def test_symlinked_lock_is_rejected(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / 'Library/Application Support/Mac CI Release Lock'
            root.mkdir(mode=0o700, parents=True)
            target = Path(home) / 'fixture'; target.write_text('fixture')
            (root / 'release.lock').symlink_to(target)
            with self.assertRaises(OSError):
                with release_lock(home): pass
            self.assertEqual(target.read_text(), 'fixture')

    def test_unprivate_lock_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / 'Library/Application Support/Mac CI Release Lock'
            root.mkdir(mode=0o700, parents=True); root.chmod(0o755)
            with self.assertRaises(ValueError):
                with release_lock(home): pass


if __name__ == '__main__': unittest.main()
