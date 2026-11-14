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
from unittest import mock

path = pathlib.Path(__file__).resolve().parents[1] / "compare-menubar-footprint.py"
spec = importlib.util.spec_from_file_location("compare_menubar_footprint", path)
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class MenubarFootprintTests(unittest.TestCase):
    def summarize_rows(self, rows):
        with tempfile.TemporaryDirectory() as folder:
            source = pathlib.Path(folder) / "samples.csv"
            output = pathlib.Path(folder) / "summary.json"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow([
                    "t", "product", "pid", "rss_bytes", "footprint_bytes",
                    "cpu_seconds", "command",
                ])
                writer.writerows(rows)
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                comparison.summarize(source, output)
            result = json.loads(output.read_text())
            self.assertEqual(json.loads(printed.getvalue()), result)
            return result

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
        result = self.summarize_rows([
            (0, "App", 10, 4 * mb, 2 * mb, 5, "/App.app/Contents/MacOS/App"),
            (10, "App", 10, 6 * mb, 3 * mb, 6, "/App.app/Contents/MacOS/App"),
            (10, "App", 11, 2 * mb, mb, 0.5, "/App.app/Contents/MacOS/Helper"),
            (20, "App", 10, 6 * mb, "", 7, "/App.app/Contents/MacOS/App"),
            (0, "Other", 20, mb, mb, 1, "/Other.app/Contents/MacOS/Other"),
        ])
        self.assertEqual(result["App"], {
            "samples": 3,
            "window_s": 20.0,
            "pids": [10, 11],
            "processes": ["App", "Helper"],
            "footprint_samples": 2,
            "footprint_missing_readings": 1,
            "footprint_mb_avg": 3.0,
            "footprint_mb_min": 2.0,
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

    def test_summarize_excludes_entire_incomplete_footprint_sample(self):
        mb = 1048576
        result = self.summarize_rows([
            (0, "App", 10, mb, 10 * mb, 0, "/App"),
            (0, "App", 11, mb, "", 0, "/Helper"),
            (10, "App", 10, mb, 2 * mb, 1, "/App"),
            (10, "App", 11, mb, 4 * mb, 1, "/Helper"),
        ])["App"]
        self.assertEqual(result["footprint_samples"], 1)
        self.assertEqual(result["footprint_missing_readings"], 1)
        for stat in ["avg", "min", "peak"]:
            self.assertEqual(result[f"footprint_mb_{stat}"], 6.0)

    def test_summarize_unavailable_footprints_and_measured_zero(self):
        result = self.summarize_rows([
            (0, "App", 10, 1048576, 1048576, 0, "/App"),
            (0, "App", 11, 1048576, "", 0, "/Helper"),
            (10, "App", 10, 1048576, "", 1, "/App"),
            (10, "App", 11, 1048576, "", 1, "/Helper"),
            (0, "Zero", 12, 0, 0, 0, "/Zero"),
        ])
        self.assertEqual(result["App"]["footprint_samples"], 0)
        self.assertEqual(result["App"]["footprint_missing_readings"], 3)
        self.assertEqual(result["App"]["rss_mb_avg"], 2.0)
        self.assertEqual(result["App"]["cpu_seconds"], 2.0)
        self.assertEqual(result["Zero"]["footprint_samples"], 1)
        self.assertEqual(result["Zero"]["footprint_missing_readings"], 0)
        for stat in ["avg", "min", "peak"]:
            self.assertIsNone(result["App"][f"footprint_mb_{stat}"])
            self.assertEqual(result["Zero"][f"footprint_mb_{stat}"], 0.0)

    def test_summarize_cpu_counter_reset_and_pid_reuse(self):
        for readings, total, peak in [
            ([(100, "/App"), (1, "/App")], 1, 10),
            ([(100, "/App"), (101, "/App"), (1, "/App"), (2, "/App")], 3, 10),
            ([(100, "/App"), (101, "/App"), (1, "/New"), (2, "/New")], 3, 10),
            ([(100, "/App"), (101, "/App"), (105, "/New"), (106, "/New")], 107, 1050),
            ([(100, "/App"), (1, "/App"), (0.5, "/App"), (1.5, "/App")], 2.5, 10),
        ]:
            with self.subTest(readings=readings):
                result = self.summarize_rows([
                    (i * 10, "App", 10, 0, 0, cpu, command)
                    for i, (cpu, command) in enumerate(readings)
                ])["App"]
                self.assertEqual(result["cpu_seconds"], total)
                span = (len(readings) - 1) * 10
                self.assertEqual(result["cpu_pct_avg"], round(100 * total / span, 3))
                self.assertEqual(result["cpu_pct_peak_interval"], peak)

    def test_summarize_detects_pid_reuse_after_gap(self):
        result = self.summarize_rows([
            (0, "App", 10, 0, 0, 100, "/App"),
            (10, "App", 11, 0, 0, 1, "/Helper"),
            (20, "App", 10, 0, 0, 1, "/App"),
            (30, "App", 10, 0, 0, 2, "/App"),
        ])["App"]
        self.assertEqual(result["cpu_seconds"], 3)
        self.assertEqual(result["cpu_pct_avg"], 10)
        self.assertEqual(result["cpu_pct_peak_interval"], 10)

    def test_sampling_accepts_zero_duration_and_warmup(self):
        with tempfile.TemporaryDirectory() as folder:
            arguments = [str(path), "--duration", "0", "--warmup", "0",
                         "--out", folder, "--product", "App=/App"]
            with mock.patch.object(sys, "argv", arguments), \
                    mock.patch.object(comparison.time, "monotonic", return_value=100), \
                    mock.patch.object(comparison.time, "sleep") as sleep, \
                    mock.patch.object(comparison, "list_procs", return_value=[(10, 0, 100, "/App")]), \
                    mock.patch.object(comparison.os, "getpid", return_value=999), \
                    mock.patch.object(comparison, "footprint_bytes", return_value=0), \
                    contextlib.redirect_stdout(io.StringIO()):
                comparison.main()
            sleep.assert_called_once_with(0)
            result = json.loads((pathlib.Path(folder) / "summary.json").read_text())["App"]
            self.assertEqual(result["samples"], 1)
            self.assertEqual(result["window_s"], 0)
            self.assertEqual(result["cpu_seconds"], 0)
            self.assertIsNone(result["cpu_pct_avg"])

    def test_sampling_uses_monotonic_time_despite_wall_clock_jumps(self):
        class Clock:
            elapsed = 0.0
            wall = 1000.0
            samples = 0

            def monotonic(self):
                return self.elapsed

            def time(self):
                return self.wall

            def sleep(self, seconds):
                self.elapsed += seconds

        clock = Clock()

        def processes():
            clock.samples += 1
            self.assertLessEqual(clock.samples, 3, "Sampling must finish after 20 elapsed seconds")
            clock.wall += 100 if clock.elapsed < 15 else -200
            return [(10, 1048576, 100 + clock.elapsed / 10, "/App")]

        with tempfile.TemporaryDirectory() as folder:
            arguments = [str(path), "--duration", "20", "--interval", "10",
                         "--warmup", "0", "--out", folder, "--product", "App=/App"]
            with mock.patch.object(sys, "argv", arguments), \
                    mock.patch.object(comparison.time, "monotonic", clock.monotonic), \
                    mock.patch.object(comparison.time, "time", clock.time), \
                    mock.patch.object(comparison.time, "sleep", clock.sleep), \
                    mock.patch.object(comparison, "list_procs", side_effect=processes), \
                    mock.patch.object(comparison.os, "getpid", return_value=999), \
                    mock.patch.object(comparison, "footprint_bytes", return_value=1048576), \
                    contextlib.redirect_stdout(io.StringIO()):
                comparison.main()
            with (pathlib.Path(folder) / "samples.csv").open() as stream:
                self.assertEqual([float(row["t"]) for row in csv.DictReader(stream)], [0, 10, 20])
            result = json.loads((pathlib.Path(folder) / "summary.json").read_text())["App"]
            self.assertEqual(clock.elapsed, 20)
            self.assertEqual(result["window_s"], 20)
            self.assertEqual(result["cpu_seconds"], 2)
            self.assertEqual(result["cpu_pct_avg"], 10)
            self.assertEqual(result["cpu_pct_peak_interval"], 10)

    def test_sampling_rejects_invalid_timing_before_creating_output(self):
        for option in ["--interval", "--duration", "--warmup"]:
            values = ["-1", "nan", "inf", "-inf"]
            if option == "--interval":
                values.append("0")
            for value in values:
                with self.subTest(option=option, value=value), \
                        tempfile.TemporaryDirectory() as folder:
                    output = pathlib.Path(folder) / "not-created"
                    arguments = [str(path), f"{option}={value}", "--out", str(output),
                                 "--product", "App=/App"]
                    with mock.patch.object(sys, "argv", arguments), \
                            mock.patch.object(comparison.time, "sleep", side_effect=AssertionError(
                                "Invalid timing must fail before warmup"
                            )) as sleep, \
                            mock.patch.object(comparison, "list_procs") as processes, \
                            contextlib.redirect_stderr(io.StringIO()) as errors:
                        with self.assertRaises(SystemExit) as raised:
                            comparison.main()
                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn("usage:", errors.getvalue())
                    self.assertIn(option, errors.getvalue())
                    self.assertFalse(output.exists())
                    sleep.assert_not_called()
                    processes.assert_not_called()

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
