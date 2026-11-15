# Contributing to TinyStats

Welcome! Reports from different Macs, clear reproductions, documentation fixes and focused code changes are all useful. You do not need access to a paid model or an Apple Developer account to contribute. Please follow our [Code of Conduct](CODE_OF_CONDUCT.md); report vulnerabilities through [Security](SECURITY.md).

## Development setup

Use macOS 14+ with a Swift 6 toolchain whose macOS SDK declares the macOS 26 Liquid Glass types used behind availability checks (Xcode 26 or newer is what we build with). The app still deploys to macOS 14, with fallback materials on earlier systems. Apple Silicon is the first validation target; the universal package also compiles Intel. Native Intel and macOS 14/15 execution must be recorded separately from cross-compilation. Python 3 is required by `scripts/build-app.sh` as well as the local validation and benchmark tools.

Fork the repository if you do not have write access, then clone your fork. Contributors with write access can clone this repository directly. Create a feature branch from an up-to-date `main`, for example `docs/history-guide` or `fix/counter-reset`. Submit changes through a pull request targeting `main`; do not commit directly to `main` or force-push shared branches.

```sh
swift test --build-system native
scripts/build-app.sh --universal
open build/TinyStats.app
```

The build writes `build/TinyStats.app` and `build/TinyStats.zip`, using ad-hoc signing by default. Developer ID signing/notarization is a maintainer distribution step, not a prerequisite for a contribution. See [Distribution](docs/DISTRIBUTION.md).

## Architecture and code style

- Swift 6, macOS 14+, AppKit. Add third-party runtime dependencies only with a measured reason.
- Keep system collection on the serial background worker queue and UI work on the main actor.
- Use the one shared, coalesced timer. No per-view timers, subprocess polling, unbounded queues/history or unsolicited network requests. The experimental traffic service's narrowly scoped one-shot lease watchdog is documented in [AGENTS.md](AGENTS.md).
- Missing or invalid readings are `nil`/unavailable, never fabricated zero. Calculate rates with monotonic elapsed time; reset baselines on wake, resume, counter reset and process reuse.
- Hardware APIs vary. Do not assume SMC/GPU/battery counters exist. The SMC collector is read-only; never add fan writes to it. Privileged traffic and fan-control experiments remain unshipped and gated.
- Keep history bounded and local. Preserve explicit saving Off, fail closed on malformed preferences, and retain Off/Clear controls.
- Disclose and authorize scheduled network destinations. Weather is off by default for new installs and enabling it is an explicit opt-in. Preserve saved explicit Weather choices and gate current location on OS permission; diagnostics/tests never enable online features implicitly.
- Owner-approved exception: eligible signed releases check GitHub for app updates once per 24 hours and prepare verified updates by default, as disclosed in the welcome tour and Settings › General › Software Update. Both preferences can be disabled; saved Off choices are preserved. Development builds, diagnostics and tests never enable update requests implicitly. See [Updates](docs/UPDATES.md) for destinations and security.
- Retain protocol sources and licenses. Never copy proprietary implementations.

`Sources/TinyStatsCore` contains models, collectors, settings and history; `Sources/CTinyStats` wraps system APIs; `Sources/TinyStats` owns AppKit and the worker. Traffic protocol, IPC/client and fan-policy foundations live in separate targets with deliberately narrow dependencies. Read [Design](docs/DESIGN.md) and [AGENTS.md](AGENTS.md) for the full rules.

Before committing Swift changes, format with:

```sh
swift format format --in-place --recursive Sources Tests Package.swift
```

## Validation before a pull request

For changes to source, tests, resources, packaging or validation, run the required gate on the final worktree:

```sh
scripts/verify-local.sh
```

It must pass the native Swift/Python suite, recursive Swift format lint, strict warnings, universal app and unbundled traffic-service packaging, slice/deployment/signature checks and local diagnostics. Treat compiler warnings as defects. Fix failures; do not waive a failure or call a partial run a pass. Rerun if relevant inputs change.

Keep the source manifest and local logs under `build/ci` locally. In the PR, summarize the host OS/build, architecture, toolchain, commit and results, and attach only sanitized relevant evidence. Do not commit generated build artifacts or personal diagnostic data. Add regression coverage for meaningful behavior changes; tests should cover calculations, resets, unavailable data and lifecycle cases as relevant. Review the final diff for privacy, bounded work/history and UI lifetime.

For collection/UI performance changes, run real diagnostics and measure the Release app with `scripts/benchmark-app.py`, following [Performance](docs/PERFORMANCE.md). Distinguish measured costs from targets, and real native UI/hardware checks from synthetic fixtures. A pass on one host is not native macOS 14/15 or Intel validation.

Documentation-only changes need `git diff --check` and a factual/link review, without rebuilding an unchanged app. There is currently no dedicated repository-wide doc/link checker. Automatic push/PR [release source checks](docs/DISTRIBUTION.md#automatic-production-releases) check workflow policy, metadata and local release validation receipts; native tests run locally. The complete local check remains the required gate.

## CI and release safety

PR checks run only on GitHub-hosted `ubuntu-latest` runners; no workflow in
this repository sends PR code to self-hosted runners. Maintainers must require
approval for all external contributors' workflow runs once that setting is
available after publication. Fork PR workflows are disabled while the repository
is private. Approved fork runs use the PR's own workflow files, so runner access
and maintainer approval remain important controls.

## Pull request workflow

1. Search existing issues and discuss large changes before implementing them. Small fixes and documentation improvements can go straight to a focused PR.
2. Work on a feature branch and keep changes limited to one problem. Include tests and documentation where behavior changes.
3. Complete the appropriate validation above, then use the [PR template](.github/pull_request_template.md) to explain the problem, result, evidence and remaining limits. Draft PRs are welcome when you need help reproducing a hardware issue or completing validation.
4. Respond to review and update your branch. Maintainers review and merge into `main`; never force-push `main`.


## Hardware diagnostics

Use the [hardware report form](https://github.com/letsopen-ai/tinystats/issues/new?template=hardware_report.yml). Include your Mac model/model identifier, chip (or Intel CPU/GPU), macOS version/build and TinyStats version or commit. Do not include a serial number or hardware UUID.

```sh
build/TinyStats.app/Contents/MacOS/TinyStats --diagnose --hardware
```

The executable may also be invoked as `TinyStats --diagnose --hardware` when it is on your PATH. This local check waits for a second slow-hardware sample; it uploads nothing and does not enable online features or request location. Paste the output after reviewing and redacting usernames, paths, addresses, precise locations and any other personal data. Describe what you expected, what was missing, and whether the app reported unavailable or a value. Add sanitized screenshots only when useful. No administrator access, helper installation or fan changes are needed.

## Project documentation

Start with the [roadmap](docs/ROADMAP.md), [compatibility notes](docs/COMPATIBILITY.md), [performance notes](docs/PERFORMANCE.md) and [distribution checklist](docs/DISTRIBUTION.md). Feature guides in [docs/](docs/) describe each module's behavior and limits.
