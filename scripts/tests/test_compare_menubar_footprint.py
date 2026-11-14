import contextlib
import csv
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / "compare-menubar-footprint.py"
spec = importlib.util.spec_from_file_location("compare_menubar_footprint", path)
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class MenubarFootprintTests(unittest.TestCase):
    def test_parse_cputime(self):
        for value, expected in [
            ("00:00.00", 0),
            ("02:03.25", 123.25),
            ("01:02:03.25", 3723.25),
            ("2-01:02:03.25", 176523.25),
        ]:
            with self.subTest(value=value):
                self.assertEqual(comparison.parse_cputime(value), expected)

    def test_summarize_sums_memory_and_accounts_for_process_arrival_and_exit(self):
        mb = 1048576
        with tempfile.TemporaryDirectory() as folder:
            source = pathlib.Path(folder) / "samples.csv"
            output = pathlib.Path(folder) / "summary.json"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow([
                    "t", "product", "pid", "rss_bytes", "footprint_bytes",
                    "cpu_seconds", "command",
                ])
                writer.writerows([
                    (0, "App", 10, 4 * mb, 2 * mb, 5, "/App.app/Contents/MacOS/App"),
                    (10, "App", 10, 6 * mb, 3 * mb, 6, "/App.app/Contents/MacOS/App"),
                    (10, "App", 11, 2 * mb, mb, 0.5, "/App.app/Contents/MacOS/Helper"),
                    (20, "App", 10, 6 * mb, "", 7, "/App.app/Contents/MacOS/App"),
                    (0, "Other", 20, mb, mb, 1, "/Other.app/Contents/MacOS/Other"),
                ])
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                comparison.summarize(source, output)
            result = json.loads(output.read_text())
            self.assertEqual(json.loads(printed.getvalue()), result)
            self.assertEqual(result["App"], {
                "samples": 3,
                "window_s": 20.0,
                "pids": [10, 11],
                "processes": ["App", "Helper"],
                "footprint_mb_avg": 2.0,
                "footprint_mb_min": 0.0,
                "footprint_mb_peak": 4.0,
                "rss_mb_avg": 6.0,
                "rss_mb_peak": 8.0,
                "cpu_seconds": 2.5,
                "cpu_pct_avg": 12.5,
                "cpu_pct_peak_interval": 15.0,
            })
            self.assertEqual(result["Other"]["samples"], 1)
            self.assertEqual(result["Other"]["cpu_seconds"], 0.0)
            self.assertIsNone(result["Other"]["cpu_pct_avg"])
            self.assertIsNone(result["Other"]["cpu_pct_peak_interval"])

    def test_summarize_requires_exactly_two_paths(self):
        for arguments in [[], ["input.csv"], ["input.csv", "output.json", "extra"]]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [sys.executable, str(path), "--summarize", *arguments],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("usage:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
