#!/usr/bin/env python3
"""Measure the real Release app using libproc. Only terminates the child it starts."""
import argparse
import ctypes
import json
import math
import hashlib
import plistlib
import os
import uuid
import pathlib
import platform
import statistics
import subprocess
import time
import tempfile
import struct
import zlib

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "rss", "footprint", "started", "exited",
        "child_user", "child_system", "child_idle", "child_interrupt", "child_pageins", "child_elapsed", "disk_read", "disk_write")]

lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int

class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

_clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_clock.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
_clock.mach_timebase_info.restype = ctypes.c_int
_timebase = MachTimebase()
if _clock.mach_timebase_info(ctypes.byref(_timebase)) or not _timebase.numer or not _timebase.denom:
    raise RuntimeError("Could not read Mach CPU counter timebase")

def ticks_to_nanoseconds(ticks, numer=None, denom=None):
    numer = _timebase.numer if numer is None else numer
    denom = _timebase.denom if denom is None else denom
    if ticks < 0 or numer <= 0 or denom <= 0:
        raise ValueError("Invalid Mach tick conversion")
    return ticks * numer // denom

def usage(pid):
    result = Usage()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(result)):
        raise RuntimeError("Could not read child process resource usage")
    return result

class PopoverPresentation:
    """Bounded diagnostic stream; never infer visibility from process liveness."""
    def __init__(self, kind="popover"):
        self.prefix = f"TinyStats:{kind}=".encode()
        self.pending = b""
        self.shown = None
        self.was_shown = False
        self.expected = None

    def feed(self, data):
        self.pending += data
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            if len(line) > 4096:
                raise RuntimeError("Oversized presentation report")
            if line == self.prefix + b"shown":
                value = True
            elif line == self.prefix + b"closed":
                value = False
            elif line == self.prefix + b"other-window":
                raise RuntimeError("Unexpected app window opened during popover workload; no valid result")
            elif line.startswith(self.prefix):
                raise RuntimeError("Invalid presentation report")
            else:
                continue
            if self.expected is not None and value != self.expected:
                raise RuntimeError("Popover visibility changed during measurement; no valid result")
            self.shown = value
            self.was_shown = self.was_shown or value
        if len(self.pending) > 4096:
            raise RuntimeError("Oversized incomplete presentation report")

    def read(self, process):
        # At most four chunks per check; normal operation emits only transitions.
        for _ in range(4):
            try:
                data = os.read(process.stdout.fileno(), 4096)
            except BlockingIOError:
                break
            if not data:
                break
            self.feed(data)

    def require(self, expected):
        if expected is False and not self.was_shown:
            raise RuntimeError("Popover never opened before close; no valid retained-memory result")
        if self.shown is None:
            raise RuntimeError("App did not report a real popover; reveal its menu-bar item before measuring; no valid result")
        if self.shown != expected:
            raise RuntimeError("Popover visibility changed or does not match the workload; no valid result")
        self.expected = expected

def presentation_kind(args):
    if args.history:
        return "history"
    if args.popover:
        return "popover"
    if args.preview or args.after_close or args.settings or args.settings_general:
        return "main"
    return None

def main_window_arguments(args):
    if presentation_kind(args) != "main":
        return []
    result = ["--preview-main-report"]
    if args.after_close or args.after_settings_close:
        result += ["--preview-main-close-after", "10"]
    return result

def presentation_result(presentation, kind):
    if kind not in (None, "main", "popover", "history"):
        raise ValueError("Unknown presentation kind")
    result = {}
    for name in ("main", "popover", "history"):
        active = kind == name and presentation is not None
        result[name + "_visibility_verified"] = active if name != "history" or kind == "history" else None
        result[name + "_shown"] = presentation.shown if active else None
        result[name + "_opening_verified"] = presentation.was_shown if active else None
    return result

def checkpoint_bytes(path):
    # An explicit fixture or our disposable store; bound the actual read even if a file grows.
    with path.open("rb") as source:
        data = source.read(8621921)
    if not 76 <= len(data) <= 8621920:
        raise RuntimeError("Checkpoint exceeds bounded format")
    return data

def checkpoint_summary(data):
    if not 76 <= len(data) <= 8621920:
        raise RuntimeError("Checkpoint exceeds bounded format")
    crc_valid = zlib.crc32(data[:-4]) & 0xffffffff == struct.unpack_from("<I", data, len(data)-4)[0]
    magic, version, metrics, tiers, reserved = struct.unpack_from("<8sHHHH", data)
    header_valid = magic == b"TNYHIST\0" and version in (1, 2, 3) and (metrics, tiers, reserved) == (12, 6, 0)
    stride = 180 if version == 1 else 420
    maximum = 325156 if version == 1 else 758596 if version == 2 else 8621920
    if len(data) > maximum:
        raise RuntimeError("Checkpoint exceeds bounded format")
    if not crc_valid or not header_valid:
        raise RuntimeError("Invalid runtime checkpoint")
    offset, retained, levels = 24, 0, []
    for expected in [600, 3600, 21600, 86400, 604800, 2419200]:
        if offset + 8 > len(data) - 4:
            raise RuntimeError("Truncated checkpoint tiers")
        span, count, reserved = struct.unpack_from("<IHH", data, offset)
        offset += 8
        if span != expected or count > 301 or reserved or offset + count * stride > len(data)-4:
            raise RuntimeError("Invalid checkpoint tier layout")
        observations = 0
        for _ in range(count):
            if offset + stride > len(data)-4:
                raise RuntimeError("Truncated checkpoint bucket")
            observations += struct.unpack_from("<I", data, offset+24)[0]
            offset += stride
            if version == 3:
                if offset + 2 > len(data)-4:
                    raise RuntimeError("Truncated checkpoint core count")
                cores = struct.unpack_from("<H", data, offset)[0]
                offset += 2
                if cores == 65535:
                    if offset + 2 > len(data)-4:
                        raise RuntimeError("Truncated checkpoint changed core layout")
                    kinds = struct.unpack_from("<H", data, offset)[0]
                    offset += 2
                    if not 1 <= kinds <= 256 or offset + kinds > len(data)-4:
                        raise RuntimeError("Invalid checkpoint changed core layout")
                    offset += kinds
                else:
                    if cores > 256 or offset + cores*17 > len(data)-4:
                        raise RuntimeError("Invalid checkpoint core layout")
                    offset += cores*17
        levels.append(dict(range_seconds=span, buckets=count, observations=observations))
        retained += count
    if offset != len(data)-4:
        raise RuntimeError("Unexpected checkpoint trailing data")
    # This is evidence metadata. SessionHistory remains the authoritative semantic decoder.
    return dict(crc_valid=True, header_valid=True, version=version, retained_buckets=retained, levels=levels)

def checkpoint_metadata(path, validate=False):
    try:
        if validate:
            # Atomic rename may replace the name between stat and open. Pin one descriptor.
            with path.open("rb") as source:
                info = os.fstat(source.fileno())
                data = source.read(8621921)
                final = os.fstat(source.fileno())
                if (len(data) != info.st_size or info.st_size != final.st_size
                        or info.st_mtime_ns != final.st_mtime_ns
                        or info.st_ctime_ns != final.st_ctime_ns):
                    raise RuntimeError("Checkpoint changed during observation")
        else:
            info = path.stat()
    except FileNotFoundError:
        return None
    result = dict(bytes=info.st_size, modified_ns=info.st_mtime_ns)
    if validate:
        result.update(checkpoint_summary(data))
    return result

def seed_history_checkpoint(source, destination):
    source = source.resolve()
    temporary_root = pathlib.Path(tempfile.gettempdir()).resolve()
    if not source.is_relative_to(temporary_root):
        raise RuntimeError("Seed only synthetic checkpoints exported into temporary storage")
    info = source.stat()
    if not source.is_file() or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise RuntimeError("Unsafe synthetic checkpoint source")
    data = checkpoint_bytes(source)
    summary = checkpoint_summary(data)
    # Destination is exclusively the new UUID-backed disposable benchmark profile.
    destination.mkdir(mode=0o700)
    destination.chmod(0o700)
    for name, content in [("history-v1.bin", data), (".history.lock", b"")]:
        path = destination / name
        with path.open("xb") as output:
            output.write(content)
        path.chmod(0o600)
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), **summary)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", default="build/TinyStats.app")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--warmup", type=float, default=15)
    parser.add_argument("--persist-history", action="store_true", help="Explicitly enable bounded numeric checkpointing in a disposable isolated history directory")
    parser.add_argument("--seed-history", type=pathlib.Path, help="Copy an explicitly generated numeric checkpoint into the disposable profile; requires --persist-history")
    parser.add_argument("--history", action="store_true", help="Measure the real session History window; visibility must remain verified")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--popover", action="store_true", help="Open the real status-item popover instead of the titled preview window")
    parser.add_argument("--settings", action="store_true", help="Open the live Menu Bar settings tab")
    parser.add_argument("--after-settings-close", action="store_true", help="Visit Settings during warm-up, then close all Settings windows before the measured window")
    parser.add_argument("--settings-general", action="store_true", help="Open General settings manually during warm-up; no Menu Bar page is visited")
    parser.add_argument("--theme", choices=["system", "light", "dark"], default="system", help="Appearance in the isolated preferences suite")
    parser.add_argument("--module", choices=["overview", "cpu", "gpu", "memory", "disks", "network", "sensors", "battery", "clock", "weather"], help="Detail module for a preview/after-close measurement")
    parser.add_argument("--after-close", action="store_true", help="Launch the preview; close it manually during warm-up to measure retained memory")
    parser.add_argument("--rules", action="store_true", help="Evaluate 32 enabled, non-firing rules in an isolated preferences suite")
    parser.add_argument("--menubar-mixed", action="store_true", help="Exercise eight readouts with mixed graph, gauge, battery and text styles")
    parser.add_argument("--calendar-events", action="store_true", help="Enable the agenda in isolated preferences without requesting Calendar permission")
    parser.add_argument("--calendar-first-weekday", type=int, choices=range(1, 8), help="Override the Time calendar week start: Sunday=1 through Saturday=7")
    parser.add_argument("--battery-formats", action="store_true", help="Seed battery state presets; manually open Battery formats and choose Example On battery during Settings warm-up")
    parser.add_argument("--world-clock-labels", action="store_true", help="Exercise six named world clocks in Date & Time using isolated public examples")
    parser.add_argument("--world-clock-seconds", action="store_true", help="Exercise six world clocks with custom seconds and relative offsets; requires --preview --module clock")
    parser.add_argument("--clock-formats", action="store_true", help="Exercise six custom two-line menu bar clocks with seconds in isolated preferences")
    parser.add_argument("--clock-graphics", action="store_true", help="Exercise six custom clocks with calendar/dial graphics, seconds, fuzzy time and relative offsets in isolated preferences")
    parser.add_argument("--network-bundles", action="store_true", help="Group kernel TCP/UDP owners by executable bundle path; requires Network details")
    parser.add_argument("--internet-checks", action="store_true", help="Explicitly enable Apple HTTPS and ipify IPv4/IPv6 requests in the isolated benchmark suite")
    parser.add_argument("--weather", action="store_true", help="Explicitly enable MET Norway for a public Oslo example location in the isolated suite")
    parser.add_argument("--weather-example", choices=["oslo", "met"], default="oslo", help="Public weather fixture: Oslo or MET documentation coordinates")
    parser.add_argument("--output")
    args = parser.parse_args()
    weather_examples = {"oslo": (59.9, 10.7, "Oslo example"), "met": (60.0, 11.0, "MET documentation example")}
    weather_lat, weather_lon, weather_name = weather_examples[args.weather_example]
    if args.weather_example != "oslo" and not args.weather:
        parser.error("--weather-example requires --weather")
    if not math.isfinite(args.duration) or not math.isfinite(args.warmup) or args.duration < 10 or args.warmup < 0:
        parser.error("Use finite duration >=10 and warmup >=0")
    if args.seed_history and not args.persist_history:
        parser.error("--seed-history requires --persist-history")
    if args.history and (args.preview or args.popover or args.settings or args.settings_general):
        parser.error("--history is a separate window workload")
    if args.history and args.module not in [None, "cpu", "gpu", "memory", "network", "disks", "battery"]:
        parser.error("--history requires a supported numeric module")
    if args.preview and args.popover:
        parser.error("Choose --preview or --popover")
    if args.history and args.after_close and args.warmup < 20:
        parser.error("Automatic History close requires warmup >=20")
    if args.popover and args.after_close and args.warmup < 20:
        parser.error("Automatic popover close requires warmup >=20")
    if presentation_kind(args) == "main" and (args.after_close or args.after_settings_close) and args.warmup < 20:
        parser.error("Automatic main-window close requires warmup >=20")
    if args.module and not (args.preview or args.popover or args.after_close or args.history):
        parser.error("--module requires --preview, --popover or --after-close")
    if args.network_bundles and not ((args.preview or args.popover or args.after_close) and args.module == "network"):
        parser.error("--network-bundles requires --preview/--popover/--after-close --module network")
    if args.calendar_first_weekday is not None and not ((args.preview or args.popover) and args.module == "clock"):
        parser.error("--calendar-first-weekday requires --preview/--popover --module clock")
    if args.after_settings_close and not (args.settings or args.settings_general):
        parser.error("--after-settings-close requires --settings or --settings-general")
    if args.battery_formats and not args.settings:
        parser.error("--battery-formats requires --settings")
    if (args.world_clock_labels or args.world_clock_seconds) and not ((args.preview or args.popover) and args.module == "clock"):
        parser.error("World-clock workloads require --preview/--popover --module clock")
    if args.clock_formats and args.clock_graphics:
        parser.error("Choose one custom clock workload")
    if args.settings and args.settings_general:
        parser.error("Choose one settings page workload")
    if (args.settings or args.settings_general) and (args.preview or args.popover or args.after_close):
        parser.error("--settings is a separate workload from detail preview/after-close")
    if args.rules and args.duration + args.warmup >= 86400:
        parser.error("Rule workload duration must be less than one day")
    app = pathlib.Path(args.app).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable_hash = hashlib.sha256((app / "Contents/MacOS/TinyStats").read_bytes()).hexdigest()
    command = [str(app / "Contents/MacOS/TinyStats")]
    if args.history:
        command.append("--preview-history")
        if args.after_close:
            command.extend(["--preview-history-close-after", "10"])
    elif args.popover:
        command.append("--preview-popover")
        if args.after_close:
            command.extend(["--preview-popover-close-after", "10"])
    elif args.preview or args.after_close:
        command.append("--preview")
    if args.settings:
        command.append("--preview-settings")
    elif args.settings_general:
        command.append("--preview-settings-general")
    kind = presentation_kind(args)
    main_presentation = kind == "main"
    command.extend(main_window_arguments(args))
    if args.module:
        command.extend(["--preview-module", args.module])
    environment = os.environ.copy()
    environment["TINYSTATS_PREFERENCES_DOMAIN"] = "TinyStats.Benchmark." + uuid.uuid4().hex
    history_directory = tempfile.TemporaryDirectory(prefix="tinystats-history-benchmark-")
    history_path = pathlib.Path(history_directory.name).resolve() / "records"
    # Always override inherited paths. Off still performs zero store I/O; checkbox availability matches production.
    environment["TINYSTATS_HISTORY_DIRECTORY"] = str(history_path)
    mode = "after-session-history-closed" if args.history and args.after_close else "open-session-history" if args.history else "after-settings-closed" if args.after_settings_close else "open-settings-general" if args.settings_general else "open-settings" if args.settings else "after-popover-closed" if args.after_close and args.popover else "after-details-closed" if args.after_close else "open-popover" if args.popover else "open-details" if args.preview else "closed-popover"
    process = None
    seeded = False
    try:
        history_seed = seed_history_checkpoint(args.seed_history, history_path) if args.seed_history else None
        settings = {"theme": args.theme, "persistHistory": args.persist_history,
                    "weather": {"enabled": False}, "calendarEvents": False,
                    "connectivityChecks": False, "publicIPChecks": False, "alerts": False}
        if args.rules:
            metrics = ["cpuUsage", "gpuUsage", "memoryUsage", "memoryPressure", "volumeUsage", "diskRead", "diskWrite", "download", "upload", "interfaceState", "sensor", "batteryLevel", "batteryPower", "powerSource", "thermalState", "storageHealth"]
            settings.update(alerts=True, rules=[dict(id=f"benchmark-{i}", metric=metrics[i % len(metrics)], threshold=0, hold=86400, enabled=True) for i in range(32)])
        if args.menubar_mixed:
            settings.update(readouts=["cpu", "gpu", "memory", "disks", "network", "sensors", "battery", "clock"],
                styles=dict(cpu="historyValue", gpu="ring", memory="horizontal", disks="pie", network="historyValue", sensors="stacked", battery="battery", clock="value"),
                appearances={module: dict(size="large", color="blue") for module in ["cpu", "gpu", "memory", "disks", "network", "sensors", "battery", "clock"]})
        if args.battery_formats:
            settings.update(readouts=["cpu", "memory", "network", "battery"], batteryMenu=dict(format="percentAndTime", customizeStates=True))
        if args.calendar_events:
            settings["calendarEvents"] = True
        if args.calendar_first_weekday is not None:
            settings["calendarFirstWeekday"] = args.calendar_first_weekday
        if args.world_clock_labels or args.world_clock_seconds:
            zones = ["UTC", "Europe/London", "America/Los_Angeles", "America/New_York", "Asia/Shanghai", "Australia/Sydney"]
            settings.update(worldClocks=zones, worldClockNames=dict(zip(zones, ["Build server", "London office", "LA team", "New York team", "Shanghai team", "Sydney lab"])))
        if args.world_clock_seconds:
            settings["worldClockFormat"] = "{hour24}:{minute}:{second} · {localOffset}"
        if args.clock_formats or args.clock_graphics:
            zones = ["UTC", "Europe/London", "America/Los_Angeles", "America/New_York", "Asia/Shanghai", "Asia/Kathmandu"]
            settings.update(readouts=["cpu", "memory", "network", "clock"],
                clockMenu=dict(custom=True, entries=[dict(name=name, zone=zone,
                    firstLine="{calendar} {name} {weekday}" if args.clock_graphics else "{name} {weekday}",
                    secondLine="{analogSeconds} {hour24}:{minute}:{second} {fuzzy} {localOffset}" if args.clock_graphics else "{hour24}:{minute}:{second} {offset}")
                    for name, zone in zip(["Build", "London", "LA", "NY", "Shanghai", "Nepal"], zones)]))
        if args.network_bundles:
            settings.update(networkTrafficGrouping="bundles", networkTrafficRevision=uuid.uuid4().hex)
        if args.internet_checks:
            settings.update(connectivityChecks=True, publicIPChecks=True, internetRevision=uuid.uuid4().hex)
        if args.weather:
            settings["weather"] = dict(enabled=True, location=dict(latitude=weather_lat, longitude=weather_lon, name=weather_name, timeZone="Europe/Oslo"), revision=uuid.uuid4().hex)
        if settings:
            data = json.dumps(settings).encode().hex()
            subprocess.run(["defaults", "write", environment["TINYSTATS_PREFERENCES_DOMAIN"], "settings", "-data", data], check=True, stdout=subprocess.DEVNULL)
            seeded = True
        presentation = PopoverPresentation(kind) if kind else None
        # AppKit logging must not fill an unread pipe and stall long workloads.
        process = subprocess.Popen(command, stdout=subprocess.PIPE if presentation else subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
        if presentation:
            os.set_blocking(process.stdout.fileno(), False)
        if args.settings_general:
            print("General opens automatically; do not visit Menu Bar.", flush=True)
        if args.after_close:
            print("The window closes itself after 10s using the shared sampler; do not inspect or interact with it." if args.popover or args.history or main_presentation else "Close the preview window during warm-up; leave the menu bar app running.", flush=True)
        if args.battery_formats:
            print("During warm-up, open Battery formats and choose Example · On battery. Examples stay in the preview, not the collector.", flush=True)
        if (args.clock_formats or args.clock_graphics) and args.settings:
            print("During warm-up, open Clock formats from Time in Menu Bar" + (" before closing all Settings windows." if args.after_settings_close else "; leave its shared-clock preview open."), flush=True)
        if args.after_settings_close:
            print("Close all Settings windows before warm-up ends; leave the menu bar app running.", flush=True)
        print(f"Warming up PID {process.pid} for {args.warmup:g}s…", flush=True)
        time.sleep(args.warmup)
        if process.poll() is not None:
            raise RuntimeError("App exited before measurement; quit any existing TinyStats instance first.")
        if presentation:
            presentation.read(process)
            presentation.require(not (args.after_close or args.after_settings_close))
        checkpoint_before = checkpoint_metadata(history_path / "history-v1.bin", validate=True)
        before = usage(process.pid)
        start = time.monotonic()
        samples = []
        print(f"Measuring {mode} for {args.duration:g}s…", flush=True)
        while time.monotonic() - start < args.duration:
            time.sleep(min(2, max(0, args.duration - (time.monotonic() - start))))
            if process.poll() is not None:
                raise RuntimeError("App exited during measurement")
            if presentation:
                presentation.read(process)
                presentation.require(not (args.after_close or args.after_settings_close))
            samples.append(usage(process.pid))
        elapsed = time.monotonic() - start
        after = samples[-1]
        checkpoint_after = checkpoint_metadata(history_path / "history-v1.bin", validate=True)
        result = dict(
            history_seed=history_seed,
            history_checkpoint_before=checkpoint_before, history_checkpoint_after=checkpoint_after,
            history_persistence=args.persist_history, history_file_bytes=(history_path / "history-v1.bin").stat().st_size if (history_path / "history-v1.bin").is_file() else 0,
            mode=mode, preferences=("eight mixed-style readouts, large font, automatic graphic colors, 2s cadence" if args.menubar_mixed else "isolated local-only baseline, stacked CPU/memory/network, 2s cadence") + (", 32 enabled rules, 24h hold prevents notifications" if args.rules else "") + (", calendar events enabled, permission never requested" if args.calendar_events else "") + (", Apple HTTPS + ipify IPv4/IPv6 checks explicitly enabled" if args.internet_checks else "") + (f", MET Norway weather explicitly enabled for {weather_name} ({weather_lat:.3f}, {weather_lon:.3f})" if args.weather else "") + (", six named world clocks" if args.world_clock_labels or args.world_clock_seconds else "") + (", custom world-clock seconds and relative offsets" if args.world_clock_seconds else "") + (", six custom two-line clocks with seconds" if args.clock_formats else "") + (", six mixed graphical two-line clocks with seconds" if args.clock_graphics else "") + (", Battery readout and per-state presets; manually opened Battery formats with explicit On battery example" if args.battery_formats else "") + (", all Settings windows closed during warm-up" if args.after_settings_close else ""),
            detail_module=(args.module or ("cpu" if args.history else "overview")) if args.preview or args.popover or args.after_close or args.history else None,
            presentation="session-history" if args.history else "status-popover" if args.popover else "preview-window" if args.preview or args.after_close else "settings" if args.settings or args.settings_general else "none",
            history_range="10 minutes" if args.history else None,
            **presentation_result(presentation, kind),
            main_auto_close_seconds=10 if main_presentation and (args.after_close or args.after_settings_close) else None,
            history_auto_close_seconds=10 if args.history and args.after_close else None,
            popover_auto_close_seconds=10 if args.popover and args.after_close else None,
            calendar_first_weekday=args.calendar_first_weekday,
            after_settings_close=args.after_settings_close, battery_formats=args.battery_formats, world_clock_labels=args.world_clock_labels, world_clock_seconds=args.world_clock_seconds, clock_formats=args.clock_formats, clock_graphics=args.clock_graphics, calendar_events=args.calendar_events, internet_checks=args.internet_checks, network_bundles=args.network_bundles, weather=args.weather, weather_example=args.weather_example if args.weather else None, theme=args.theme, settings_preview=args.settings and not args.after_settings_close, settings_open=(args.settings or args.settings_general) and not args.after_settings_close, settings_page=None if args.after_settings_close else "general" if args.settings_general else "menubar" if args.settings else None, settings_visited_page="general" if args.settings_general else "menubar" if args.settings else None, app_version=info["CFBundleShortVersionString"], executable_sha256=executable_hash, system=platform.platform(), machine=platform.machine(),
            cpu_counter_units="Mach absolute ticks converted to nanoseconds", mach_timebase_numer=_timebase.numer, mach_timebase_denom=_timebase.denom,
            duration_seconds=round(elapsed, 3), warmup_seconds=args.warmup,
            cpu_percent_one_core=round(ticks_to_nanoseconds((after.user+after.system)-(before.user+before.system))/1e9/elapsed*100, 4),
            rss_mib_before=round(before.rss/2**20, 2), rss_mib_after=round(after.rss/2**20, 2),
            footprint_mib_before=round(before.footprint/2**20, 2), footprint_mib_after=round(after.footprint/2**20, 2),
            rss_mib_median=round(statistics.median(s.rss for s in samples)/2**20, 2),
            rss_mib_peak=round(max(s.rss for s in samples)/2**20, 2),
            footprint_mib_peak=round(max(s.footprint for s in samples)/2**20, 2),
            idle_wakeups_per_second=round((after.idle_wakeups-before.idle_wakeups)/elapsed, 2),
            disk_bytes_written=after.disk_write-before.disk_write,
            app_bytes=sum(p.stat().st_size for p in app.rglob("*") if p.is_file()))
        rendered = json.dumps(result, indent=2)
        print(rendered, flush=True)
        if args.output:
            pathlib.Path(args.output).write_text(rendered+"\n")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if seeded:
            subprocess.run(["defaults", "delete", environment["TINYSTATS_PREFERENCES_DOMAIN"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        history_directory.cleanup()

if __name__ == "__main__":
    main()
