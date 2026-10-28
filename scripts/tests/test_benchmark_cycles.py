import importlib.util
import json
import os
import tempfile
import types
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("benchmark_cycles", pathlib.Path(__file__).parents[1] / "benchmark-cycles.py")
cycles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cycles)


def event(kind, number, uptime, complete=False):
    return b"TinyStats:cycle=" + json.dumps(dict(event=kind, cycle=number, uptime=uptime, complete=complete)).encode() + b"\n"


def feed_study(stream, count=2, complete=True):
    stream.feed(event("baseline", 0, 0), 0.1)
    now = 30
    for number in range(1, count + 1):
        stream.feed(b"TinyStats:popover=shown\n" + event("shown", number, now), now + 0.1)
        now += 6
        stream.feed(b"TinyStats:popover=closed\n" + event("closed", number, now), now + 0.1)
        now += 10
        stream.feed(event("settled", number, now), now + 0.1)
    if complete:
        now += stream.tail
        stream.feed(event("complete", count, now, True), now + 0.1)
    return now


class CycleTests(unittest.TestCase):
    def test_complete_stream_requires_native_pairs_and_actual_settle_intervals(self):
        stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
        end = feed_study(stream)
        self.assertTrue(stream.complete)
        self.assertEqual(end, 77)
        self.assertEqual(len(stream.events), 8)
        self.assertFalse(stream.native_shown)
        self.assertIsNone(stream.pending_native)

    def test_partial_pipe_reads_preserve_order_and_do_not_fabricate_transitions(self):
        stream = cycles.CycleStream(1, 30, 6, 10, tail=15)
        line = event("baseline", 0, 0)
        stream.feed(line[:15], 0)
        self.assertEqual(stream.events, [])
        stream.feed(line[15:], 0.1)
        stream.feed(b"TinyStats:popover=shown\n", 30.1)
        self.assertTrue(stream.pending_native)
        stream.feed(event("shown", 1, 30), 30.2)
        self.assertEqual(stream.phase, "shown")

    def test_missing_duplicate_reordered_early_and_other_window_transitions_fail(self):
        fragments = [
            event("shown", 1, 30),
            b"TinyStats:popover=shown\n" + event("shown", 2, 30),
            b"TinyStats:popover=shown\n" + event("shown", 1, 29),
            b"TinyStats:popover=closed\n",
            b"TinyStats:popover=other-window\n",
            event("baseline", 0, 1),
        ]
        for fragment in fragments:
            stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
            stream.feed(event("baseline", 0, 0), 0.1)
            with self.subTest(fragment=fragment), self.assertRaises(RuntimeError):
                stream.feed(fragment, 30.1 if b"shown" in fragment else 1.1)
        for kind, at in [("early-close", 35), ("early-settle", 45), ("wrong-complete", 46)]:
            stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
            stream.feed(event("baseline", 0, 0), 0.1)
            stream.feed(b"TinyStats:popover=shown\n" + event("shown", 1, 30), 30.1)
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                if kind == "early-close":
                    stream.feed(b"TinyStats:popover=closed\n" + event("closed", 1, at), at + 0.1)
                else:
                    stream.feed(b"TinyStats:popover=closed\n" + event("closed", 1, 36), 36.1)
                    stream.feed(event("settled", 1, at, kind == "wrong-complete"), at + 0.1)

    def test_failed_show_clock_reset_invalid_values_and_stalled_reports_fail(self):
        for fragment, received in [
            (b'TinyStats:cycle={"event":"failed","cycle":0,"uptime":null,"complete":false,"reason":"clock"}\n', 0),
            (event("baseline", True, 0), 0.1),
            (event("baseline", 0, float("nan")), 0.1),
            (event("baseline", 0, float("inf")), 0.1),
            (event("baseline", 0, -1), 0.1),
            (event("baseline", 0, 0), 3),
            (event("baseline", 0, 0), -1),
            (b'TinyStats:cycle={"event":"baseline"}\n', 0),
        ]:
            with self.subTest(fragment=fragment), self.assertRaises(RuntimeError):
                cycles.CycleStream(2, 30, 6, 10, tail=15).feed(fragment, received)
        stream = cycles.CycleStream(1, 30, 6, 10, tail=15)
        stream.feed(event("baseline", 0, 5), 5.1)
        with self.assertRaises(RuntimeError):
            stream.feed(b"TinyStats:popover=shown\n" + event("shown", 1, 4), 4.1)

    def test_failure_reason_is_retained_but_arbitrary_fields_are_not(self):
        stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
        failure = dict(event="failed", cycle=1, uptime=31, complete=False, reason="interrupted")
        with self.assertRaisesRegex(RuntimeError, "interrupted"):
            stream.feed(b"TinyStats:cycle=" + json.dumps(failure).encode() + b"\n", 31.1)
        self.assertEqual(stream.failure, failure)
        self.assertFalse(stream.complete)
        stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
        failure["arbitrary"] = "must not retain"
        with self.assertRaises(RuntimeError):
            stream.feed(b"TinyStats:cycle=" + json.dumps(failure).encode() + b"\n", 31.1)
        self.assertIsNone(stream.failure)

    def test_oversized_data_and_post_completion_activity_fail(self):
        for data in [b"x" * 4097, b"x" * 4097 + b"\n"]:
            with self.assertRaises(RuntimeError):
                cycles.CycleStream(2, 30, 6, 10, tail=15).feed(data, 0)
        stream = cycles.CycleStream(1, 30, 6, 10, tail=15)
        feed_study(stream, 1)
        with self.assertRaises(RuntimeError):
            stream.feed(b"TinyStats:popover=shown\n", 47)

    def test_aggregates_use_interior_samples_both_median_and_peak_and_actual_times(self):
        stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
        end = feed_study(stream)
        samples = [dict(uptime=t, rss=t * 2**20, footprint=(100 - t) * 2**20, cpu_ns=t * 1_000_000, writes=t * 10) for t in range(79)]
        profile = cycles.profile_intervals(stream, samples)
        self.assertEqual(profile["baseline"]["samples"], 19)  #10...28, not transition/startup samples.
        self.assertEqual(profile["baseline"]["rss_mib_median"], 19)
        self.assertEqual(profile["baseline"]["rss_mib_peak"], 28)
        self.assertEqual(profile["baseline"]["footprint_mib_median"], 81)
        self.assertEqual(profile["baseline"]["footprint_mib_peak"], 90)
        self.assertEqual(profile["cycles"][0]["opened"]["samples"], 3)  #32,33,34
        self.assertEqual(profile["cycles"][0]["closed_settled"]["samples"], 5)  #40...44
        self.assertEqual(profile["final_closed"]["start_uptime"], end - 15)
        self.assertEqual(profile["native_cutoff_uptime"], end)
        self.assertEqual(profile["maximum_sample_gap_seconds"], 1)
        self.assertAlmostEqual(profile["baseline"]["cpu_percent_one_core"], 0.1)
        self.assertEqual(profile["baseline"]["disk_bytes_written"], 180)
        with self.assertRaises(RuntimeError):
            cycles.profile_intervals(stream, [])
        with self.assertRaises(RuntimeError):
            cycles.profile_intervals(cycles.CycleStream(1, 30, 6, 10, tail=15), samples)

    def test_native_completion_after_tail_is_mandatory(self):
        stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
        settled = feed_study(stream, complete=False)
        self.assertFalse(stream.complete)
        with self.assertRaises(RuntimeError):
            cycles.profile_intervals(stream, [])
        with self.assertRaises(RuntimeError):
            stream.feed(event("complete", 2, settled + 14, True), settled + 14.1)

    def test_final_drain_rejects_queued_failure_or_other_window(self):
        samples = [dict(uptime=t, rss=t * 2**20, footprint=(100 - t) * 2**20,
                        cpu_ns=t * 1_000_000, writes=0) for t in range(79)]
        for late, expected in [
            (b"", None),
            (b"TinyStats:popover=other-window\n", "Unexpected native presentation transition"),
            (b'TinyStats:cycle={"event":"failed","cycle":2,"uptime":77.1,"complete":false,"reason":"interrupted"}\n', "Cycle probe rejected its lifecycle: interrupted"),
        ]:
            stream = cycles.CycleStream(2, 30, 6, 10, tail=15)
            feed_study(stream)
            reader_fd, writer = os.pipe()
            os.set_blocking(reader_fd, False)
            with os.fdopen(reader_fd, "rb", buffering=0) as reader:
                try:
                    if late:
                        os.write(writer, late)
                    process = types.SimpleNamespace(stdout=reader)
                    if expected:
                        with self.assertRaisesRegex(RuntimeError, expected):
                            cycles.finish_profile(stream, samples, process, lambda: 77.2)
                    else:
                        self.assertEqual(cycles.finish_profile(stream, samples, process, lambda: 77.2)["native_cutoff_uptime"], 77)
                finally:
                    os.close(writer)

    def test_sampling_gaps_and_uncovered_cutoff_are_rejected(self):
        for times, cutoff in [([0, 1, 5, 6], 6), ([0, 1, 2], 5), ([0, 1, 1], 2), ([0, float("nan")], 2)]:
            with self.subTest(times=times), self.assertRaises(RuntimeError):
                cycles.sample_gap([dict(uptime=t) for t in times], cutoff)
        self.assertEqual(cycles.sample_gap([dict(uptime=t) for t in [0, 2, 4]], 4), 2)

    def test_launch_hashes_and_build_manifest_identify_the_measured_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            executable, manifest = root / "TinyStats", root / "manifest.json"
            executable.write_bytes(b"test executable")
            initial = cycles.launch_provenance(executable)
            self.assertEqual(len(initial["harness_sha256"]), 64)
            self.assertEqual(len(initial["backend_sha256"]), 64)
            self.assertIsNone(initial["build_source"])
            record = dict(executable_sha256=initial["executable_sha256"], base_revision="a" * 40, source_input_digest="b" * 64)
            manifest.write_text(json.dumps(record))
            identified = cycles.launch_provenance(executable, manifest)
            self.assertEqual(identified["build_source"]["source_input_digest"], "b" * 64)
            executable.write_bytes(b"different executable")
            with self.assertRaises(RuntimeError):
                cycles.launch_provenance(executable, manifest)
            manifest.write_bytes(b"x" * 131073)
            with self.assertRaises(RuntimeError):
                cycles.launch_provenance(executable, manifest)

    def test_counter_reset_and_empty_intervals_cannot_be_zero_cost_results(self):
        records = [dict(uptime=t, rss=1, footprint=2, cpu_ns=10 - t, writes=0) for t in range(4)]
        with self.assertRaises(RuntimeError):
            cycles.summarize(records, 0, 4, 0, 0)
        with self.assertRaises(RuntimeError):
            cycles.summarize(records, 0, 4, 4, 0)


if __name__ == "__main__":
    unittest.main()
