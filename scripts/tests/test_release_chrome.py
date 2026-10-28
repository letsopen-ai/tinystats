"""Exercise source policy and raw-byte scanning; bytes do not model Swift literals."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

GATE = pathlib.Path(__file__).resolve().parents[1] / "check-release-chrome.py"


class ReleaseChromeTests(unittest.TestCase):
    def run_gate(self, data):
        with tempfile.TemporaryDirectory(prefix="tinystats-release-chrome-") as directory:
            binary = pathlib.Path(directory) / "TinyStats executable"
            if data is not None:
                binary.write_bytes(data)
            return subprocess.run(
                [sys.executable, str(GATE), str(binary)],
                capture_output=True, text=True, check=False,
            )

    def test_clean_production_text_passes(self):
        result = self.run_gate(b"\xcf\xfa\xed\xfe\x00TinyStats\x00Unavailable\x00No available readings\x00")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_contiguous_banner_and_fragment_bytes_fail_in_supported_encodings(self):
        for text in [
            "TinyStats UI Fixture · synthetic data",
            "TinyStats UI Fixture",
            "Weather locale fixture · synthetic data",
            "SYNTHETIC-DATA",
        ]:
            for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
                with self.subTest(text=text, encoding=encoding):
                    result = self.run_gate(b"\x00" * 32 + text.encode(encoding) + b"\x00")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Fixture chrome in Release executable", result.stderr)

    def test_contamination_after_nul_padding_fails(self):
        # Whole-file traversal, not a simulated Mach-O slice/header parser.
        result = self.run_gate(b"TinyStats\x00" + b"\x00" * 4096 + b"UI Fixture")
        self.assertNotEqual(result.returncode, 0)

    def test_empty_or_missing_executable_fails_closed(self):
        for data in (b"", None):
            with self.subTest(data=data):
                self.assertNotEqual(self.run_gate(data).returncode, 0)

    def run_source_gate(self, text, *, binary_data=None):
        with tempfile.TemporaryDirectory(prefix="tinystats-source-chrome-") as directory:
            root = pathlib.Path(directory)
            sources = root / "Sources"
            nested = sources / "TinyStats"
            nested.mkdir(parents=True)
            (nested / "Main.swift").write_text(text, encoding="utf-8")
            command = [sys.executable, str(GATE), "--sources", str(sources)]
            if binary_data is not None:
                binary = root / "TinyStats"
                binary.write_bytes(binary_data)
                command.append(str(binary))
            return subprocess.run(command, capture_output=True, text=True, check=False)

    def test_clean_nested_sources_and_binary_pass(self):
        result = self.run_source_gate('let label = "Unavailable"\n', binary_data=b"TinyStats")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_short_swift_literals_fail_even_when_binary_has_no_marker(self):
        # Swift can encode short strings as immediate values rather than text.
        # Reject source literals regardless of how the compiler represents them.
        for marker in ("UI Fixture", "Synthetic data", "SYNTHETIC-DATA"):
            with self.subTest(marker=marker):
                result = self.run_source_gate(f'let label = "{marker}"\n', binary_data=b"TinyStats")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Fixture chrome in production source", result.stderr)
                self.assertIn("Main.swift:1:", result.stderr)

    def test_debug_blocks_and_comments_are_also_rejected(self):
        for text in ('#if DEBUG\nlet label = "UI Fixture"\n#endif\n', '// synthetic data\n'):
            with self.subTest(text=text):
                result = self.run_source_gate(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Fixture chrome in production source", result.stderr)

    def test_missing_empty_or_non_directory_sources_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="tinystats-source-chrome-") as directory:
            root = pathlib.Path(directory)
            empty = root / "empty"
            empty.mkdir()
            file = root / "file"
            file.write_text("clean", encoding="utf-8")
            for sources in (root / "missing", empty, file):
                with self.subTest(sources=sources):
                    result = subprocess.run(
                        [sys.executable, str(GATE), "--sources", str(sources)],
                        capture_output=True, text=True, check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_source_mode_still_checks_contaminated_binary(self):
        result = self.run_source_gate('let label = "Unavailable"\n', binary_data=b"UI Fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fixture chrome in Release executable", result.stderr)


if __name__ == "__main__":
    unittest.main()
