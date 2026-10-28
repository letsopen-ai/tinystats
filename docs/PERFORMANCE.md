# Performance

TinyStats aims to be a low-overhead menu bar monitor: one shared collection timer, power-aware cadence, work only for visible pages, and no routine disk writes or network requests unless you opt in to a feature that needs them.

## How to measure

Build the app, then use the benchmark harness:

```sh
scripts/build-app.sh --universal
python3 scripts/benchmark-app.py --warmup 15 --duration 60 --output build/closed.json
python3 scripts/benchmark-app.py --warmup 15 --duration 60 --preview --output build/open.json
# Requests a normal close after 10 s; allow settling before sampling.
python3 scripts/benchmark-app.py --after-close --warmup 30 --duration 30 --output build/after-close.json
# Settings workloads: --settings opens Menu Bar, --settings-general opens General.
python3 scripts/benchmark-app.py --settings-general --warmup 30 --duration 60
```

The harness creates an isolated, local-only preferences suite (stacked CPU/memory/network readouts at a 2-second cadence by default), launches the actual `.app` executable, and terminates only its own child process. It reports:

- **CPU** as a percentage of one core, from libproc Mach CPU ticks converted with the queried timebase.
- **RSS** (resident set size), which includes resident shared framework and code pages.
- **Physical footprint** (`ri_phys_footprint`), macOS's per-process memory accounting. RSS and footprint are reported separately and are not interchangeable.
- **Idle wakeups** per second and **bytes written** by the process.

Run `python3 scripts/benchmark-app.py --help` for other workloads (menu bar styles, History, Weather, clocks, rules and more). For meaningful numbers, keep the bundle fixed, avoid other builds or tests during the run, and do not interact with the app while sampling.

## Recent observations

Single Release runs on an Apple M4 Mac (arm64), 0.35.x builds, with eight mixed menu bar readouts at a 2-second cadence, History saving on with a fresh store, and online features off:

| Build / scenario | CPU (% of one core) | Median RSS | Peak footprint | Writes during sampling |
| --- | ---: | ---: | ---: | ---: |
| 0.35.4, popover closed (30 s warm-up + 30 s) | 1.28% | 81.6 MiB | 20.7 MiB | 0 B |
| 0.35.5, after opening and closing a popover (20 s + 15 s) | 1.14% | 98.9 MiB | 38.6 MiB | 0 B |

The 0.35.4 universal app was 9.2 MB. With the minimal default readouts, the earliest builds measured roughly 0.02–0.04% of one core and a ~15 MiB fresh-launch footprint; the mixed eight-readout workload above is much heavier than the defaults.

## CPU measurement erratum (0.29.0)

Before 0.29.0, process/self CPU percentages derived from rusage/libproc treated Mach absolute ticks as nanoseconds. On Apple Silicon (timebase 125/3) that understated CPU by about 41.67×. Machine-wide CPU ratios, RSS, physical footprint, writes and timings were unaffected. The C collectors and both Python benchmark samplers now convert using the queried timebase, with conversion/saturation regressions. Do not compare pre-0.29.0 process CPU figures with current ones.

## Caveats and open work

- These are single observations on one machine, not controlled benchmarks; treat them as indicative only.
- After native windows or popovers are opened and closed, macOS keeps framework caches, so footprint stays higher than a fresh launch.
- The original targets (<40 MiB RSS and <25 MiB fresh-launch footprint) are not fully met; memory reduction is ongoing work.
- Not yet measured: Intel runtime overhead, overhead on macOS 14/15, long-duration stability, laptop battery impact, and every menu bar style combination.
