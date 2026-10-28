#!/usr/bin/env python3
"""Bounded same-process native-popover lifecycle study. Stops only its own child.

Quit any existing TinyStats instance first. No AX, captures, heap tools or network
requests. All settings are disposable/local-only. Resource intervals exclude
transition edges; raw observations retain actual monotonic lifecycle timestamps.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import platform
import re
import plistlib
import statistics
import subprocess
import sys
import time
import uuid


class CycleStream:
    def __init__(self, count, baseline, opened, closed, tail=60):
        self.count, self.baseline, self.opened, self.closed, self.tail = count, baseline, opened, closed, tail
        self.pending = b""
        self.events = []
        self.phase = None
        self.cycle = 0
        self.native_shown = False
        self.pending_native = None
        self.complete = False
        self.last_time = None
        self.failure = None

    def feed(self, data, received_at):
        self.pending += data
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            if len(line) > 4096:
                raise RuntimeError("Oversized diagnostic line")
            if line.startswith(b"TinyStats:popover="):
                value = line.removeprefix(b"TinyStats:popover=")
                expected = b"closed" if self.phase == "shown" else b"shown"
                if (value != expected or self.pending_native is not None or self.complete
                        or self.phase not in ("baseline", "shown", "settled")):
                    raise RuntimeError("Unexpected native presentation transition")
                self.pending_native = value == b"shown"
            elif line.startswith(b"TinyStats:cycle="):
                self.accept(json.loads(line.removeprefix(b"TinyStats:cycle=")), received_at)
        if len(self.pending) > 4096:
            raise RuntimeError("Oversized incomplete diagnostic line")

    def accept(self, event, received_at):
        if not isinstance(event, dict):
            raise RuntimeError("Invalid cycle event")
        if event.get("event") == "failed":
            reason = event.get("reason")
            cycle, uptime = event.get("cycle"), event.get("uptime")
            if (set(event) != {"event", "cycle", "uptime", "complete", "reason"}
                    or reason not in ("clock", "unexpected-show", "show-failed", "unexpected-close", "interrupted")
                    or type(cycle) is not int or not 0 <= cycle <= self.count
                    or event.get("complete") is not False
                    or (uptime is not None and (type(uptime) not in (int, float) or not math.isfinite(uptime)))):
                raise RuntimeError("Invalid failure report")
            self.failure = dict(event)
            raise RuntimeError("Cycle probe rejected its lifecycle: " + reason)
        if set(event) != {"event", "cycle", "uptime", "complete"}:
            raise RuntimeError("Unexpected cycle fields")
        kind, cycle, uptime, complete = (event[k] for k in ("event", "cycle", "uptime", "complete"))
        if (type(cycle) is not int or type(complete) is not bool
                or type(uptime) not in (int, float) or not math.isfinite(uptime)
                or uptime < 0 or self.complete
                or (self.last_time is not None and uptime < self.last_time)):
            raise RuntimeError("Invalid cycle sequence or timestamp")
        # Both clocks must agree at runtime. Refuse suspended/stalled delivery rather
        # than align a stale marker to a fresh resource reading. No wall clock rates.
        if not math.isfinite(received_at) or not -0.01 <= received_at - uptime <= 2:
            raise RuntimeError("Lifecycle and sampling clocks diverged or delivery stalled")
        previous = self.events[-1] if self.events else None
        if kind == "baseline":
            valid = self.phase is None and cycle == 0 and not complete and self.pending_native is None
        elif kind == "shown":
            valid = (self.phase in ("baseline", "settled") and cycle == self.cycle + 1
                     and cycle <= self.count and not complete and self.pending_native is True)
            if self.phase == "baseline":
                valid = valid and uptime - previous["uptime"] >= self.baseline - 0.001
        elif kind == "closed":
            valid = (self.phase == "shown" and cycle == self.cycle and not complete
                     and self.pending_native is False
                     and uptime - previous["uptime"] >= self.opened - 0.001)
        elif kind == "settled":
            valid = (self.phase == "closed" and cycle == self.cycle
                     and not complete and self.pending_native is None
                     and uptime - previous["uptime"] >= self.closed - 0.001)
        elif kind == "complete":
            valid = (self.phase == "settled" and cycle == self.cycle == self.count
                     and complete and not self.native_shown and self.pending_native is None
                     and uptime - previous["uptime"] >= self.tail - 0.001)
        else:
            valid = False
        if not valid:
            raise RuntimeError("Missing, duplicate, early or reordered lifecycle transition")
        self.events.append(dict(event, received_uptime=received_at))
        if len(self.events) > 2 + self.count * 3:
            raise RuntimeError("Cycle event bound exceeded")
        self.phase, self.last_time, self.complete = kind, uptime, complete
        if kind == "shown":
            self.cycle, self.native_shown = cycle, True
        elif kind == "closed":
            self.native_shown = False
        self.pending_native = None

    def read(self, process, now):
        for _ in range(4):
            try:
                data = os.read(process.stdout.fileno(), 4096)
            except BlockingIOError:
                break
            if not data:
                break
            self.feed(data, now())


def summarize(samples, start, end, trim_start, trim_end):
    selected = [s for s in samples if start + trim_start <= s["uptime"] < end - trim_end]
    if len(selected) < 2:
        raise RuntimeError("Insufficient interior samples for a lifecycle interval")
    first, last = selected[0], selected[-1]
    duration = last["uptime"] - first["uptime"]
    if duration <= 0 or last["cpu_ns"] < first["cpu_ns"] or last["writes"] < first["writes"]:
        raise RuntimeError("Invalid monotonic resource counters")
    return dict(start_uptime=start, end_uptime=end, trim_start_seconds=trim_start,
                trim_end_seconds=trim_end, samples=len(selected),
                sampled_duration_seconds=duration,
                rss_mib_median=statistics.median(s["rss"] for s in selected) / 2**20,
                rss_mib_peak=max(s["rss"] for s in selected) / 2**20,
                footprint_mib_median=statistics.median(s["footprint"] for s in selected) / 2**20,
                footprint_mib_peak=max(s["footprint"] for s in selected) / 2**20,
                cpu_percent_one_core=(last["cpu_ns"] - first["cpu_ns"]) / 1e9 / duration * 100,
                disk_bytes_written=last["writes"] - first["writes"])


def sample_gap(samples, cutoff=None):
    selected = [s for s in samples if cutoff is None or s["uptime"] <= cutoff]
    if len(selected) < 2 or any(not math.isfinite(s["uptime"]) for s in selected):
        raise RuntimeError("Insufficient finite resource samples")
    gaps = [b["uptime"] - a["uptime"] for a, b in zip(selected, selected[1:])]
    if any(gap <= 0 for gap in gaps):
        raise RuntimeError("Resource sample clock regressed")
    if cutoff is not None:
        gaps.append(cutoff - selected[-1]["uptime"])
    maximum = max(gaps)
    if maximum > 2:
        raise RuntimeError("Resource sampling stalled; no valid peak observations")
    return maximum


def launch_provenance(executable, manifest=None):
    paths = {"executable": executable, "harness": pathlib.Path(__file__),
             "backend": pathlib.Path(__file__).with_name("benchmark-app.py")}
    provenance = {key + "_sha256": hashlib.sha256(path.read_bytes()).hexdigest() for key, path in paths.items()}
    provenance["build_source"] = None
    if manifest is not None:
        with manifest.open("rb") as source:
            data = source.read(131073)
        if len(data) > 131072:
            raise RuntimeError("Build manifest exceeds bound")
        record = json.loads(data)
        if (not isinstance(record, dict)
                or not isinstance(record.get("base_revision"), str)
                or not isinstance(record.get("source_input_digest"), str)
                or record.get("executable_sha256") != provenance["executable_sha256"]
                or not re.fullmatch(r"[0-9a-f]{40}", record.get("base_revision", ""))
                or not re.fullmatch(r"[0-9a-f]{64}", record.get("source_input_digest", ""))):
            raise RuntimeError("Build source manifest does not identify this executable")
        provenance["build_source"] = dict(base_revision=record["base_revision"],
                                          source_input_digest=record["source_input_digest"],
                                          manifest_sha256=hashlib.sha256(data).hexdigest())
    return provenance


def profile_intervals(stream, samples):
    if not stream.complete or stream.pending_native is not None or stream.pending:
        raise RuntimeError("Incomplete native cycle study")
    events = stream.events
    baseline = summarize(samples, events[0]["uptime"], events[1]["uptime"], 10, 1)
    cycles = []
    for index in range(stream.count):
        shown, closed, settled = events[1 + index * 3:4 + index * 3]
        cycles.append(dict(cycle=index + 1,
                           opened=summarize(samples, shown["uptime"], closed["uptime"], 2, 1),
                           closed_settled=summarize(samples, closed["uptime"], settled["uptime"], 4, 1)))
    cutoff = events[-1]["uptime"]
    tail = summarize(samples, events[-2]["uptime"], cutoff, 2, 1)
    return dict(baseline=baseline, cycles=cycles, final_closed=tail,
                native_cutoff_uptime=cutoff, maximum_sample_gap_seconds=sample_gap(samples, cutoff))


def finish_profile(stream, samples, process, clock):
    # The app's terminal marker observes actual closed state on its main actor.
    # It orders prior interruption reports before the cutoff. Drain again so a
    # late queued failure cannot be lost between the last read and finalization.
    stream.read(process, clock)
    return profile_intervals(stream, samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("build/TinyStats.app"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--build-manifest", type=pathlib.Path)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--baseline", type=float, default=30)
    parser.add_argument("--opened", type=float, default=6)
    parser.add_argument("--closed", type=float, default=10)
    parser.add_argument("--tail", type=float, default=60)
    parser.add_argument("--theme", choices=["light", "dark"], default="dark")
    parser.add_argument("--module", choices=["overview", "cpu", "gpu", "memory", "network", "disks", "sensors", "battery"], default="network")
    args = parser.parse_args()
    if not 1 <= args.cycles <= 50:
        parser.error("Use 1...50 cycles")
    for name, value, low, high in [("baseline", args.baseline, 20, 120), ("opened", args.opened, 6, 60), ("closed", args.closed, 8, 120), ("tail", args.tail, 15, 120)]:
        if not math.isfinite(value) or not low <= value <= high:
            parser.error(f"Use finite {name} in {low}...{high} seconds")
    if args.output.exists():
        parser.error("Output already exists; use a new study path")
    app = args.app.resolve(strict=True)
    executable = app / "Contents/MacOS/TinyStats"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.niechen.tinystats":
        parser.error("Not a TinyStats application bundle")
    spec = importlib.util.spec_from_file_location("benchmark_app", pathlib.Path(__file__).with_name("benchmark-app.py"))
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    backend.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    backend.lib.proc_pidpath.restype = ctypes.c_int
    domain = "TinyStats.CycleProbe." + str(uuid.uuid4())
    settings = dict(interval=2, theme=args.theme, readouts=["cpu", "memory", "network"],
                    weather=dict(enabled=False), connectivityChecks=False, publicIPChecks=False,
                    calendarEvents=False, persistHistory=False, alerts=False, rules=[])
    stream = CycleStream(args.cycles, args.baseline, args.opened, args.closed, args.tail)
    samples = []
    provenance = launch_provenance(executable, args.build_manifest)
    result = dict(schema_version=1, status="invalid", cpu_counter_units="Mach ticks converted to nanoseconds", mach_timebase_numer=backend._timebase.numer, mach_timebase_denom=backend._timebase.denom, provenance=provenance, scope="unreleased diagnostic cycle build; real production popover paths, no AX or heap instrumentation",
                  executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                  app_version=info["CFBundleShortVersionString"], system=platform.platform(),
                  machine=platform.machine(), settings=settings, started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  requested=dict(cycles=args.cycles, baseline=args.baseline, opened=args.opened,
                                 closed=args.closed, tail=args.tail, module=args.module),
                  sample_interval_seconds=1, clock="macOS monotonic uptime, verified against native markers",
                  aggregation="Interior phase samples; baseline trim10s/1s, open2s/1s, closed4s/1s, final2s/1s; sampled peaks, not lifetime/startup peaks")
    process = None
    seeded = False
    try:
        subprocess.run(["defaults", "write", domain, "settings", "-data", json.dumps(settings).encode().hex()], check=True, stdout=subprocess.DEVNULL)
        seeded = True
        environment = dict(os.environ, TINYSTATS_PREFERENCES_DOMAIN=domain)
        command = [str(executable), "--preview-popover", "--preview-module", args.module,
                   "--preview-popover-cycles", str(args.cycles), "--cycle-baseline-seconds", str(args.baseline),
                   "--cycle-open-seconds", str(args.opened), "--cycle-closed-seconds", str(args.closed),
                   "--cycle-tail-seconds", str(args.tail)]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
        os.set_blocking(process.stdout.fileno(), False)
        started = time.monotonic()
        timeout = args.baseline + args.cycles * (args.opened + args.closed + 8) + args.tail + 60
        last_settled = 0
        print("Cycle probe started; keep the native popover visible and do not interact.", flush=True)
        while True:
            now = time.monotonic()
            if now - started > timeout:
                raise RuntimeError("Cycle study timed out; no complete result")
            if process.poll() is not None:
                raise RuntimeError("App exited; quit other TinyStats instances before starting")
            path = ctypes.create_string_buffer(4096)
            if not backend.lib.proc_pidpath(process.pid, path, len(path)) or os.path.realpath(os.fsdecode(path.value)) != str(executable):
                raise RuntimeError("Child executable identity changed")
            stream.read(process, time.monotonic)
            if stream.complete:
                result.update(finish_profile(stream, samples, process, time.monotonic))
                if launch_provenance(executable, args.build_manifest) != provenance:
                    raise RuntimeError("Build, harness or backend changed during measurement")
                result["status"] = "valid"
                break
            before = time.monotonic()
            value = backend.usage(process.pid)
            after = time.monotonic()
            if after - before > 0.1:
                raise RuntimeError("Resource read stalled; no clean cycle result")
            samples.append(dict(uptime=(before + after) / 2, rss=value.rss, footprint=value.footprint,
                                cpu_ns=backend.ticks_to_nanoseconds(value.user + value.system), writes=value.disk_write))
            if len(samples) > 1:
                if samples[-1]["uptime"] - samples[-2]["uptime"] > 2:
                    raise RuntimeError("Resource sampling stalled; no valid peak observations")
            settled = sum(e["event"] == "settled" for e in stream.events)
            if settled > last_settled:
                print(f"Verified native cycle {settled}/{args.cycles} settled.", flush=True)
                last_settled = settled
            time.sleep(1)
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        result.update(events=stream.events, samples=samples, failure=stream.failure)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if seeded:
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with args.output.open("x") as output:
            output.write(json.dumps(result, indent=2) + "\n")
    print("Completed native cycles and final closed tail; aggregate results saved.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"No valid cycle result: {error}", file=sys.stderr)
        sys.exit(1)
