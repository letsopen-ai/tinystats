#!/usr/bin/env python3
r"""Sample memory (phys_footprint, RSS) and CPU time of menu bar apps on macOS.

Start both apps, then run from the repository root (Python 3 standard library only):

    python3 scripts/compare-menubar-footprint.py \
        --duration 600 --interval 10 --warmup 120 --out comparison-run \
        --product 'tinyStats=/TinyStats\.app/Contents/' \
        --product 'iStat Menus=iStat Menus[^/]*\.app/Contents/'

Recompute a saved run without sampling running apps:

    python3 scripts/compare-menubar-footprint.py \
        --summarize comparison-run/samples.csv comparison-run/summary.json

Every process whose full command line matches a product regex is attributed to it;
choose patterns that cover its helpers too. Memory is summed per sample. CPU % is
derived from cumulative CPU-time deltas (ps TIME), as a percentage of one core
averaged over each interval. Summary memory values use MB = 1,048,576 bytes.

Processes that start and exit between samples are not captured. Footprint stats
use only samples where every matched process has a reading; the summary reports
complete sample and missing reading counts, with null stats if none are complete.
Elapsed time and scheduling use a monotonic clock. A CPU counter decrease or
command change starts a new process baseline.
Output stays local; samples.csv contains process IDs and full command lines,
which may include personal paths. Review it before sharing.
"""

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import time


def parse_cputime(s):
    # ps TIME formats: [[dd-]hh:]mm:ss.cc
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [float(p) for p in s.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def list_procs():
    out = subprocess.run(
        ["ps", "-axo", "pid=,rss=,time=,command="], capture_output=True, text=True
    ).stdout
    procs = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", line)
        if m:
            procs.append(
                (
                    int(m.group(1)),
                    int(m.group(2)) * 1024,
                    parse_cputime(m.group(3)),
                    m.group(4),
                )
            )
    return procs


def footprint_bytes(pid):
    r = subprocess.run(
        ["footprint", "-p", str(pid), "-f", "bytes", "--noCategories"],
        capture_output=True,
        text=True,
    )
    m = re.search(r"phys_footprint:\s+(\d+)\s+B", r.stdout)
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--duration", type=float, default=600)
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--warmup", type=float, default=120)
    ap.add_argument("--out", default=".")
    ap.add_argument("--product", action="append", required=True)
    a = ap.parse_args()
    for option, value in [("interval", a.interval), ("duration", a.duration), ("warmup", a.warmup)]:
        if not math.isfinite(value) or (value <= 0 if option == "interval" else value < 0):
            bound = "> 0" if option == "interval" else ">= 0"
            ap.error(f"--{option} must be finite and {bound}")
    products = {}
    for spec in a.product:
        name, rx = spec.split("=", 1)
        products[name] = re.compile(rx)
    me = os.getpid()
    os.makedirs(a.out, exist_ok=True)
    print(f"warm-up {a.warmup}s", flush=True)
    time.sleep(a.warmup)
    with open(os.path.join(a.out, "samples.csv"), "w", newline="") as raw:
        w = csv.writer(raw)
        w.writerow(
            ["t", "product", "pid", "rss_bytes", "footprint_bytes", "cpu_seconds", "command"]
        )
        start = time.monotonic()
        n = 0
        while True:
            t = time.monotonic() - start
            for pid, rss, cpu, cmd in list_procs():
                if pid == me:
                    continue
                for name, rx in products.items():
                    if rx.search(cmd):
                        w.writerow(
                            [f"{t:.2f}", name, pid, rss, footprint_bytes(pid), f"{cpu:.2f}", cmd]
                        )
            raw.flush()
            n += 1
            if t >= a.duration:
                break
            time.sleep(max(0, a.interval - ((time.monotonic() - start) - t)))
    summarize(os.path.join(a.out, "samples.csv"), os.path.join(a.out, "summary.json"))


def summarize(path, out):
    with open(path) as raw:
        rows = list(csv.DictReader(raw))
    res = {}
    for name in sorted({r["product"] for r in rows}):
        pr = [r for r in rows if r["product"] == name]
        ts = sorted({float(r["t"]) for r in pr})
        fp, rss, cpu_tot = [], [], []
        footprint_missing_readings = 0
        cpu_previous = {}
        for t in ts:
            at = [r for r in pr if float(r["t"]) == t]
            missing = sum(r["footprint_bytes"] == "" for r in at)
            footprint_missing_readings += missing
            if not missing:
                fp.append(sum(int(r["footprint_bytes"]) for r in at))
            rss.append(sum(int(r["rss_bytes"]) for r in at))
            snapshot = {}
            for r in at:
                pid, cpu, command = r["pid"], float(r["cpu_seconds"]), r["command"]
                previous = cpu_previous.get(pid)
                generation = previous[2] if previous else 0
                if previous and (cpu < previous[0] or command != previous[1]):
                    generation += 1
                snapshot[(pid, generation)] = cpu
                cpu_previous[pid] = (cpu, command, generation)
            cpu_tot.append(snapshot)
        # CPU seconds consumed inside the window, keyed by PID and generation
        # so counter resets and command changes start a new process. A process
        # already running at the first sample contributes (last - first); one
        # appearing mid-window has a zero baseline and contributes its last value.
        # Processes that start and exit between two samples are not captured.
        first_seen, last_seen = {}, {}
        for snap in cpu_tot:
            for p, v in snap.items():
                first_seen.setdefault(p, v)
                last_seen[p] = v
        total_cpu = sum(
            last_seen[p] - (first_seen[p] if p in cpu_tot[0] else 0.0)
            for p in last_seen
        )
        pcts = []
        for i in range(1, len(ts)):
            d = sum(v - cpu_tot[i - 1].get(p, 0.0) for p, v in cpu_tot[i].items())
            pcts.append(100.0 * d / (ts[i] - ts[i - 1]))
        span = ts[-1] - ts[0]

        def mb(b):
            return round(b / 1048576, 1)

        res[name] = {
            "samples": len(ts),
            "window_s": round(span, 1),
            "pids": sorted({int(r["pid"]) for r in pr}),
            "processes": sorted({r["command"].split("/Contents/MacOS/")[-1] for r in pr}),
            "footprint_samples": len(fp),
            "footprint_missing_readings": footprint_missing_readings,
            "footprint_mb_avg": mb(sum(fp) / len(fp)) if fp else None,
            "footprint_mb_min": mb(min(fp)) if fp else None,
            "footprint_mb_peak": mb(max(fp)) if fp else None,
            "rss_mb_avg": mb(sum(rss) / len(rss)),
            "rss_mb_peak": mb(max(rss)),
            "cpu_seconds": round(total_cpu, 2),
            "cpu_pct_avg": round(100.0 * total_cpu / span, 3) if span else None,
            "cpu_pct_peak_interval": round(max(pcts), 2) if pcts else None,
        }
    with open(out, "w") as summary:
        json.dump(res, summary, indent=2)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--summarize":
        ap = argparse.ArgumentParser(
            description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
        )
        ap.add_argument("--summarize", nargs=2, metavar=("CSV", "JSON"), required=True)
        a = ap.parse_args()
        summarize(*a.summarize)
    else:
        main()
