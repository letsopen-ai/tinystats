# TinyStats engineering guidelines

These guidelines apply to everyone changing TinyStats, whether you work by hand or with coding tools. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

- Work on feature branches and open pull requests targeting `main`. Do not commit directly to `main`; never force-push `main` or shared branches.
- Track release readiness in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) and open work in [docs/ROADMAP.md](docs/ROADMAP.md). Repository settings are maintainer-managed.
- Module identity graphics may use the named, appearance-aware sRGB constants centralized in `SystemStyle.modulePalettes` (the dopamine accents experiment); this is the sole exception to semantic/system colours. Keep text neutral, states semantic, and glass/solid accessibility treatments intact. See [Design](docs/DESIGN.md#dopamine-accents-experiment).
- Swift 6, macOS 14+ deployment target, AppKit. Building requires a macOS SDK that declares the macOS 26 Liquid Glass types (Xcode 26 or newer is what we build with). No third-party runtime dependencies without a measured reason.
- Keep system collection on the serial worker queue. Keep UI work on the main actor.
- One shared, coalesced timer. No subprocess polling, per-view timers, unbounded queues/history, or unsolicited network requests. Scheduled internet requests require user authorization and disclosed destinations; diagnostics/tests never enable them implicitly. Weather is off by default for new installs; enabling it is an explicit opt-in. Current-location coordinates wait for TinyStats’ own OS location authorization. Preserve existing explicit Weather choices.
- Owner-approved exception: eligible signed releases check GitHub for app updates once per 24 hours and prepare verified updates by default, as disclosed in the welcome tour and Settings › General › Software Update. Both preferences can be disabled; saved Off choices are preserved. Development builds, diagnostics and tests never enable update requests implicitly. See [Updates](docs/UPDATES.md) for destinations and security.
- The optional privileged traffic service may use one active, one-shot 30-second startup/session lease watchdog to close its read-only session after a stalled client. It must not poll independently, run by default or install/register itself. Keep it unbundled until signed-peer/root runtime validation passes.
- Numeric history saving defaults on. Preserve saved explicit Off choices; malformed explicit values fail closed. Keep storage bounded and local, and expose Off/Clear controls in History.
- Missing readings are nil/unavailable, not 0. Monotonic elapsed time drives rates. Wake, resume, resets, and process reuse must not produce spikes.
- Hardware APIs vary. Never silently assume a missing SMC/GPU/battery counter exists. Never write SMC fan settings in the read-only collector.
- Test pure calculations and regression cases. Use `swift test --build-system native`; build with `scripts/build-app.sh --universal`. Treat compiler warnings as defects in local validation.
- Use `swift format format --in-place --recursive Sources Tests Package.swift` before committing Swift changes.
- Run real diagnostics and measure the Release app with `scripts/benchmark-app.py`. Keep measured numbers and promises distinct.
- Source protocol research and retain licenses. Never copy proprietary implementation.

## Before submitting

- For source, tests, resources, packaging or validation changes, run `scripts/verify-local.sh` on the final tree. It must pass the Swift/Python tests, recursive Swift format lint, strict warnings, universal app and unbundled traffic-service packaging, slice/deployment/signature checks and local diagnostics. Never bypass a check or report a partial run as a pass.
- Review the final diff for correctness, unavailable-data handling, privacy, bounded collection/history and UI lifetime. Add regression coverage for meaningful behavior changes.
- Documentation-only changes need `git diff --check` and a link/factual review.
- A pass on one host proves only that host. Universal compilation and a 14.0 deployment target are not native macOS 14/15 or Intel runtime validation.
- Do not commit build output, logs, credentials, signing material or personal diagnostic data (usernames, paths, locations, serial numbers).
