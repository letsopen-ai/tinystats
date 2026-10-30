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


## Process app grouping cost and bounds

CPU/Memory **Apps** reuses the full existing general process scan only while one of those detail pages is visible and already requests that scan. Processes mode, Disk I/O, closed details and Network do not run the new general app projection. There is no extra recurring scan, timer, polling loop, subprocess or internet request; a live grouping action can request one immediate sample through the shared scheduler. Network retains its separate complete 1,024-owner ledger and cached ready-snapshot projection.

Cost estimate (operation counts, **not a measured whole-app CPU/RSS promise**): for P accessible processes, at most 8,192, the added general work is up to three guarded native calls per process (rusage/path/rusage, including PID start and executable UUID checks), one dictionary aggregation pass, and two sorts of at most P groups before keeping eight CPU and eight memory rows. This is O(P + G log G), O(P) temporary state, with a single reused 4,096-byte path buffer. Native raw rows and calculated readings are checked for matching PID/index order before bundle projection. Path strings decode the existing NUL-terminated buffer without an intermediate mapped byte array. Paths are fetched again to observe exec changes; there are **zero filesystem stat calls** in collection. Pure lexical path resolution caches both bundle/non-bundle results, capped at 256 paths shorter than 4,096 UTF-8 bytes (less than 1 MiB path payload plus names/containers), admitted on a first-available-slot basis (not LRU eviction), pruned to paths observed in the latest scan and cleared when general scanning/grouping stops or baselines reset. Scan-local path membership is bounded by P and released after projection. The existing 8,192-row collection cap remains an accessible bounded inventory, not proof of every process on an arbitrarily large system.

Only the two eight-row projections cross to the main actor; no full process history/ledger is retained for UI regrouping. NSWorkspace icon and bundle display-name lookup occur only for actually drawn summary rows or realized All readings cells, with a 32-entry FIFO display cache per detail presentation (shared between its table and summary), including failures/fallback icons. Accepted tradeoff: the first visible miss performs synchronous Bundle/NSWorkspace metadata lookup on the main actor. Keys are bundle paths, not mtimes; same-path app updates can remain stale until eviction or reopening the detail. This avoids per-paint stat calls and another asynchronous UI lifetime; no first-paint latency or whole-app savings have been measured. Those native icon objects have framework-dependent allocation sizes, so 32 entries is an object bound, not a measured byte cap. Each icon draws at 16 points; repeated renders hit the cache. Network gains at most eight retained bundle paths in its existing display snapshot. No app paths, icons or names enter persisted history/preferences/logs.

The change is validated with bounded/cache/aggregation regressions and synthetic gallery fixtures. Whole-app Release overhead under real process churn and Intel/macOS 14/15 runtime cost remain unmeasured; the maintainer’s full verification and benchmark workflow is separate.

Grouping changes on visible CPU/Memory rearm the existing shared timer/schedule for an immediate sample; they do not reset process rate baselines or restart the unrelated Network ledger. Pause/sleep suppress collection. The deliberate one-shot response to a user action adds no recurring polling or retained full scan. CPU partial sums retain an unmeasured-member count in the same eight-row projections, with no full UI process ledger. All readings reloads only changed body cells when its grouping header remains at the same index, preserving the native control/focus; structural refreshes restore focus. These are bounded operation/lifetime changes, not measured performance claims.
