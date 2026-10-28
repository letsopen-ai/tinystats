"""A closed/reopened popover must never masquerade as an uninterrupted open run."""
import importlib.util
import pathlib
import os
import subprocess
import sys
import struct
import tempfile
import zlib
import unittest
from types import SimpleNamespace

path = pathlib.Path(__file__).resolve().parents[1] / "benchmark-app.py"
spec = importlib.util.spec_from_file_location("benchmark_app", path)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class PopoverPresentationTests(unittest.TestCase):
    def test_main_general_launch_and_closed_state_have_distinct_provenance(self):
        options = dict(history=False, popover=False, preview=False, after_close=False,
                       settings=False, settings_general=True, after_settings_close=True)
        args = SimpleNamespace(**options)
        self.assertEqual(benchmark.presentation_kind(args), "main")
        self.assertEqual(benchmark.main_window_arguments(args),
                         ["--preview-main-report", "--preview-main-close-after", "10"])
        stream = benchmark.PopoverPresentation("main")
        stream.feed(b"TinyStats:main=shown\nTinyStats:main=closed\n")
        stream.require(False)
        result = benchmark.presentation_result(stream, "main")
        self.assertTrue(result["main_visibility_verified"])
        self.assertFalse(result["main_shown"])
        self.assertTrue(result["main_opening_verified"])
        self.assertFalse(result["popover_visibility_verified"])
        self.assertIsNone(result["popover_shown"])
        self.assertIsNone(result["history_visibility_verified"])

    def test_main_child_window_invalidates_even_if_it_closes_between_samples(self):
        stream = benchmark.PopoverPresentation("main")
        with self.assertRaisesRegex(RuntimeError, "Unexpected app window"):
            stream.feed(b"TinyStats:main=shown\nTinyStats:main=other-window\nTinyStats:main=shown\n")
        unseen = benchmark.PopoverPresentation("main")
        unseen.feed(b"TinyStats:main=closed\n")
        with self.assertRaisesRegex(RuntimeError, "never opened"):
            unseen.require(False)

    def test_cpu_timebase_conversion_is_not_raw_nanoseconds(self):
        self.assertEqual(benchmark.ticks_to_nanoseconds(24_000_000, 125, 3), 1_000_000_000)
        self.assertEqual(benchmark.ticks_to_nanoseconds(1_000_000_000, 1, 1), 1_000_000_000)
        self.assertEqual(benchmark.ticks_to_nanoseconds(2**64-1, 125, 3), (2**64-1)*125//3)
        with self.assertRaises(ValueError):
            benchmark.ticks_to_nanoseconds(1, 1, 0)

    def assert_invalid_launch(self, arguments, message):
        result = subprocess.run(
            [sys.executable, str(path), "--app", "/nonexistent/TinyStats.app", *arguments],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn(message, result.stderr)

    def test_bundle_mode_requires_explicit_network_details_before_launch(self):
        self.assert_invalid_launch(["--network-bundles"], "requires --preview/--popover/--after-close --module network")
        self.assert_invalid_launch(["--network-bundles", "--preview", "--module", "cpu"], "requires --preview/--popover/--after-close --module network")
        self.assert_invalid_launch(["--network-bundles", "--history", "--module", "network"], "requires --preview/--popover/--after-close --module network")

    def empty_checkpoint(self):
        data = struct.pack("<8sHHHHQ", b"TNYHIST\0", 1, 12, 6, 0, 0)
        data += b"".join(struct.pack("<IHH", span, 0, 0) for span in [600, 3600, 21600, 86400, 604800, 2419200])
        return data + struct.pack("<I", zlib.crc32(data) & 0xffffffff)

    def test_history_seed_requires_explicit_saving_before_app_launch(self):
        self.assert_invalid_launch(["--seed-history", "/nonexistent/fixture"], "requires --persist-history")
        with self.assertRaisesRegex(RuntimeError, "temporary storage"):
            benchmark.seed_history_checkpoint(pathlib.Path("/Users/fixture/history.bin"), pathlib.Path("/unused"))

    def test_history_seed_is_private_disposable_and_keeps_source_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "fixture.bin"
            data = self.empty_checkpoint()
            source.write_bytes(data)
            destination = root / "disposable"
            seeded = benchmark.seed_history_checkpoint(source, destination)
            metadata = benchmark.checkpoint_metadata(destination / "history-v1.bin", validate=True)
            self.assertEqual(source.read_bytes(), data)
            self.assertEqual((destination / "history-v1.bin").read_bytes(), data)
            self.assertEqual(seeded["bytes"], 76)
            self.assertEqual(metadata["retained_buckets"], 0)
            self.assertEqual(len(metadata["levels"]), 6)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
            for name in ["history-v1.bin", ".history.lock"]:
                self.assertEqual((destination / name).stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                benchmark.seed_history_checkpoint(source, destination)

    def test_history_metadata_rejects_corruption_oversize_and_invalid_tier_layout(self):
        empty = self.empty_checkpoint()
        invalid_layout = bytearray(empty[:-4])
        struct.pack_into("<H", invalid_layout, 28, 302)
        invalid_layout += struct.pack("<I", zlib.crc32(invalid_layout) & 0xffffffff)
        corrupt = bytearray(empty)
        corrupt[-1] ^= 1
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "fixture.bin"
            for invalid in [b"", bytes(758597), corrupt, invalid_layout]:
                source.write_bytes(invalid)
                with self.assertRaises(RuntimeError):
                    benchmark.seed_history_checkpoint(source, root / "disposable")
                self.assertFalse((root / "disposable").exists())
            self.assertIsNone(benchmark.checkpoint_metadata(root / "absent", validate=True))

    def test_history_metadata_accepts_v2_stride_and_retains_v1_support(self):
        legacy = pathlib.Path(__file__).resolve().parents[2] / "Tests/TinyStatsTestSupport/Fixtures/history-v1.bin"
        old = legacy.read_bytes()
        self.assertEqual(benchmark.checkpoint_summary(old)["version"], 1)
        current = bytearray(old[:24])
        struct.pack_into("<H", current, 8, 2)
        offset = 24
        for _ in range(6):
            header = old[offset:offset+8]
            _, count, _ = struct.unpack("<IHH", header)
            current += header
            offset += 8
            for _ in range(count):
                current += old[offset:offset+180]
                current += bytes(240)  # Unknown legacy aggregates, canonical zero.
                offset += 180
        current += struct.pack("<I", zlib.crc32(current) & 0xffffffff)
        summary = benchmark.checkpoint_summary(current)
        self.assertEqual(summary["version"], 2)
        self.assertEqual(summary["retained_buckets"], 6)
        self.assertEqual(len(current), 76 + 6 * 420)
        wrong_stride = bytearray(old)
        struct.pack_into("<H", wrong_stride, 8, 2)
        struct.pack_into("<I", wrong_stride, len(wrong_stride)-4, zlib.crc32(wrong_stride[:-4]) & 0xffffffff)
        with self.assertRaises(RuntimeError):
            benchmark.checkpoint_summary(wrong_stride)

    def test_history_v2_metadata_bound_covers_full_format_and_rejects_extra_byte(self):
        data = bytearray(struct.pack("<8sHHHHQ", b"TNYHIST\0", 2, 12, 6, 0, 0))
        for span in [600, 3600, 21600, 86400, 604800, 2419200]:
            data += struct.pack("<IHH", span, 301, 0)
            for index in range(301):
                instant = index * span / 300 + 0.25
                data += struct.pack("<dddIIHH", instant, instant, 1, 1, 0, 0, 0)
                data += bytes(144 + 240)
        data += struct.pack("<I", zlib.crc32(data) & 0xffffffff)
        self.assertEqual(len(data), 758596)
        self.assertEqual(benchmark.checkpoint_summary(data)["retained_buckets"], 1806)
        with self.assertRaisesRegex(RuntimeError, "bounded"):
            benchmark.checkpoint_summary(data + b"x")

    def test_history_v3_metadata_reads_variable_core_counts_and_rejects_bad_extents(self):
        data = bytearray(struct.pack("<8sHHHHQ", b"TNYHIST\0", 3, 12, 6, 0, 0))
        for index, span in enumerate([600, 3600, 21600, 86400, 604800, 2419200]):
            data += struct.pack("<IHH", span, 1, 0)
            data += struct.pack("<dddIIHH", 1, 1, 1, 1, 0, 0, 0) + bytes(384)
            cores = [0, 1, 10, 256, 65535, 2][index]
            data += struct.pack("<H", cores)
            if cores == 65535:
                data += struct.pack("<HBB", 2, 1, 2)
            else:
                data += struct.pack("<BfffI", 0, 20, 20, 20, 1) * cores
        data += struct.pack("<I", zlib.crc32(data) & 0xffffffff)
        summary = benchmark.checkpoint_summary(data)
        self.assertEqual(summary["version"], 3)
        self.assertEqual(summary["retained_buckets"], 6)
        bad = bytearray(data)
        struct.pack_into("<H", bad, 452, 257)
        struct.pack_into("<I", bad, len(bad)-4, zlib.crc32(bad[:-4]) & 0xffffffff)
        with self.assertRaisesRegex(RuntimeError, "core layout"):
            benchmark.checkpoint_summary(bad)
        truncated = data[:-6]
        truncated += struct.pack("<I", zlib.crc32(truncated) & 0xffffffff)
        with self.assertRaises(RuntimeError):
            benchmark.checkpoint_summary(truncated)

    def test_history_metadata_pins_the_same_file_across_atomic_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "history.bin"
            replacement = root / "next.bin"
            source.write_bytes(self.empty_checkpoint())
            replacement.write_bytes(self.empty_checkpoint())
            os.utime(source, ns=(1000000000, 1000000000))
            os.utime(replacement, ns=(2000000000, 2000000000))
            class ReplacingPath:
                def stat(self):
                    return source.stat()
                def open(self, *args):
                    os.replace(replacement, source)
                    return source.open(*args)
            metadata = benchmark.checkpoint_metadata(ReplacingPath(), validate=True)
            self.assertEqual(metadata["modified_ns"], source.stat().st_mtime_ns)
            self.assertTrue(metadata["crc_valid"])

    def test_history_requires_its_own_supported_window_workload(self):
        self.assert_invalid_launch(["--history", "--preview"], "separate window workload")
        self.assert_invalid_launch(["--history", "--module", "weather"], "supported numeric module")

    def test_history_has_its_own_verified_state_and_rejects_close_or_other_windows(self):
        for invalid in [b"closed", b"other-window"]:
            state = benchmark.PopoverPresentation("history")
            state.feed(b"TinyStats:popover=shown\n")
            with self.assertRaises(RuntimeError):
                state.require(True)
            state.feed(b"TinyStats:history=shown\n")
            state.require(True)
            with self.assertRaises(RuntimeError):
                state.feed(b"TinyStats:history=" + invalid + b"\n")

    def test_auto_close_requires_warmup_before_any_app_is_launched(self):
        self.assert_invalid_launch(
            ["--popover", "--after-close", "--warmup", "19"], "warmup >=20")

    def test_history_close_requires_warmup_before_launch(self):
        self.assert_invalid_launch(["--history", "--after-close", "--warmup", "19"], "warmup >=20")

    def test_week_start_workload_requires_time_page_before_launch(self):
        self.assert_invalid_launch(
            ["--calendar-first-weekday", "2"], "requires --preview/--popover --module clock")

    def test_unbounded_and_invalid_intervals_are_rejected_before_launch(self):
        for flag, value in [("--duration", "inf"), ("--warmup", "nan"), ("--warmup", "inf")]:
            with self.subTest(flag=flag, value=value):
                self.assert_invalid_launch([flag, value], "Use finite duration")

    def test_fragmented_reports_and_warmup_transitions(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"TinyStats:popover=sh")
        with self.assertRaises(RuntimeError):
            state.require(True)
        state.feed(b"own\nTinyStats:popover=closed\nTinyStats:popover=shown\n")
        state.require(True)
        state.feed(b"TinyStats:popover=shown\n")
        state.require(True)

    def test_close_and_reopen_between_checks_invalidates_open_measurement(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"TinyStats:popover=shown\n")
        state.require(True)
        with self.assertRaises(RuntimeError):
            state.feed(b"TinyStats:popover=closed\nTinyStats:popover=shown\n")

    def test_after_close_cannot_hide_a_reopen(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"TinyStats:popover=shown\nTinyStats:popover=closed\n")
        state.require(False)
        with self.assertRaises(RuntimeError):
            state.feed(b"TinyStats:popover=shown\nTinyStats:popover=closed\n")

    def test_refused_opening_cannot_pass_as_after_close(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"TinyStats:popover=closed\n")
        with self.assertRaises(RuntimeError):
            state.require(False)

    def test_missing_wrong_and_malformed_states_are_not_results(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"unrelated startup text\n")
        with self.assertRaises(RuntimeError):
            state.require(False)
        state.feed(b"TinyStats:popover=closed\n")
        with self.assertRaises(RuntimeError):
            state.require(True)
        with self.assertRaises(RuntimeError):
            state.feed(b"TinyStats:popover=maybe\n")

    def test_complete_and_incomplete_lines_are_bounded(self):
        for data in [b"x" * 4097, b"x" * 4097 + b"\n"]:
            with self.assertRaises(RuntimeError):
                benchmark.PopoverPresentation().feed(data)

    def test_settings_opened_during_warmup_cannot_pass_as_closed_popover(self):
        state = benchmark.PopoverPresentation()
        state.feed(b"TinyStats:popover=shown\nTinyStats:popover=closed\n")
        with self.assertRaises(RuntimeError):
            state.feed(b"TinyStats:popover=other-window\n")


if __name__ == "__main__":
    unittest.main()
