# Distribution and release checklist

TinyStats can be built from source with an ad-hoc signature (see the [README](../README.md#install)). The automatic production-release pipeline below requires Developer ID signing and Apple notarization; configuration alone does not complete the release-readiness checklist.

## Reproducible build

Run `scripts/build-app.sh --universal`. Each architecture is compiled separately with an explicit macOS 14 deployment target before the slices are combined with `lipo`, so the build does not inherit the host SDK's deployment target. The `.app` contains the executable, `Info.plist`, icon, license and third-party notices; the script verifies the signature before creating `build/TinyStats.zip`. The build fetches no remote runtime components, and no signing credentials are stored in the repository.

By default the signature is ad-hoc for local development. A downloaded ad-hoc build may be blocked by Gatekeeper. Public binary distribution requires Developer ID signing and notarization; do not tell users to disable Gatekeeper.

## Release chrome check

Synthetic screenshot/QA fixtures must never ship in the production app. Before signing or packaging Release output, `scripts/build-app.sh` runs [check-release-chrome.py](../scripts/check-release-chrome.py) with `--sources Sources` and the linked app executable:

- The source check rejects the ASCII markers `UI Fixture`, `synthetic data` and `synthetic-data` (case-insensitive) anywhere under `Sources/`, including comments and `#if DEBUG` blocks.
- The binary check scans every slice of the executable for longer banner strings containing those markers, stored as contiguous UTF-8 or UTF-16LE/BE bytes.

For an app archived some other way, run `python3 scripts/check-release-chrome.py --sources Sources <Archive.app>/Contents/MacOS/TinyStats` from the exact source checkout used to build it. These checks cover known literal fixture labels; other synthetic UI still needs review.

CPU/Memory/Network app grouping retains the existing bounded sampling and persisted choice. Its synthetic light/dark gallery and strict host tests do not complete release readiness: the maintainer’s final-tree `verify-local.sh`, real process-churn measurement and native macOS 14/15/Intel checks remain required. See [Performance](PERFORMANCE.md#process-app-grouping-cost-and-bounds).

## Signed binary release checklist

- [x] Developer ID signing completes unattended and notarization credentials are configured.
- [x] Build with `TINYSTATS_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh --universal`, submit the ZIP with `xcrun notarytool submit build/TinyStats.zip --keychain-profile <profile> --wait`, staple the app (`xcrun stapler staple build/TinyStats.app`), repackage, and confirm with `spctl --assess --type execute -vv build/TinyStats.app`.
- [x] `scripts/verify-local.sh` passes on the release native inputs on the MacBook; the committed receipt matches the release source.
- [ ] Tests and the Release `--diagnose` run pass natively on macOS 14 (arm64), macOS 15 (arm64) and an Intel Mac for the release commit. A universal build compiled on one host is not runtime evidence for other OS versions or architectures; see [Compatibility](COMPATIBILITY.md).
- [ ] Validate the System redesign in light/dark and purple/green/graphite accents, including Overview resize, toolbar actions, sidebar/History navigation, all inset Settings forms, picture styles, Separate/One layout with compact geometry, switches, Save/Apply/Cancel, authorization actions and unavailable hardware. Offscreen render fixtures are supplementary evidence.
- [ ] Spot-check representative hardware: more than one Apple Silicon generation, a laptop with a battery, and a fan-equipped model.
- [ ] Check sleep/wake, external storage hot-plug, network/VPN switching, notched menu bars, Light/Dark appearance (including a light menu bar), launch at login and notification permission denial.
- [ ] Review the known gaps in the [roadmap](ROADMAP.md) and decide which are acceptable for the release.
- [ ] Reproduce the [performance](PERFORMANCE.md) measurements on representative hardware.
- [ ] Publish checksums and installation instructions with the release; add a Homebrew cask once a stable signed download URL exists.

## Organization release verification — 5 November 2026

[TinyStats 0.36.5 build 68](https://github.com/letsopen-ai/tinystats/releases/tag/v0.36.5)
was built, Developer ID signed, notarized, stapled and published by
[the M4 organization release job](https://github.com/letsopen-ai/tinystats/actions/runs/41873473716).
Its annotated tag and public manifest identify source
`53bf05506392ff83ea0fd875c38c23035f02acd0`. Tests ran locally on the MacBook,
not on the M4: the complete gate passed 714 Swift tests plus Python tests,
strict lint/warnings, universal app/service packaging and diagnostics.

A separate MacBook download of the published ZIP matched its SHA-256
`795c6399b0b16e0eb7cf0052e5249a58cb87b25cd0267f5e888be91497dee9e0`.
The tag source and app version/build matched the manifest; signature verification,
stapler validation and Gatekeeper assessment passed, and both arm64/x86_64 slices
were present. This did not install or launch the downloaded app and does not
complete the other hardware, older-OS, Intel runtime or UX checks above.

## Automatic production releases

Branch pushes and same-repository PRs run Ubuntu metadata-only `Release source checks`. A successful main
push CI may start `Production release` on the dedicated M4 `release-runner`
account. The job checks the triggering CI and current main against GitHub,
then skips a version that already has a tag. It checks out the exact source in
a separate directory and verifies a committed local validation receipt before
loading signing secrets. Run `python3 scripts/local_release_validation.py record`
on the MacBook after committing native inputs, then commit the receipt. That
command runs the complete `verify-local.sh` gate locally. The M4 does not run tests. Fork PRs do not receive signing credentials. Only trusted main
source may use this runner and its signing authority.

The job imports the existing Developer ID identity into a temporary keychain,
checks its team and fingerprint, creates a temporary notarization profile, and
runs `scripts/release_signed.py`. It builds universal Release output, requires
Accepted Apple notarization, staples and validates the ticket, and verifies
Gatekeeper, signature, team, version and architectures. The ZIP, SHA-256 sums
and public manifest are uploaded to a draft GitHub Release and downloaded for
byte comparison before publication. No privileged traffic service is bundled.
A successful workflow or configuration alone does not qualify the migration:
verify a new signed release and independently download its assets.

`VERSION` and `Resources/Info.plist` must agree. Advance both marketing versions
and the plist build number in a reviewed main change to publish a new version.
A previously tagged `vX.Y.Z` is skipped; existing artifacts are never replaced.
Tag collisions, incomplete drafts, notarization rejection, stale main or a
cancelled release request fail closed. Inspect and reconcile failed drafts and
attempts before retrying; automatic retry does not overwrite them. Job-scoped
private credentials are removed on normal completion or cancellation. If the
runner or machine is forcibly terminated, inspect its private staging directory
before retrying; the next attempt refuses to proceed while material remains.
Inspect failed job output promptly: later runner checkout cleanup can remove
its build directory. Keep any retained files private and monitor disk capacity.

Actions → Production release reports the result. A skipped version is not a new
release. The physical-device, minimum-OS/Intel runtime and UX checks above
remain separate from this automation.

## Welcome redesign candidate — 0.37.0 (72)

The five-step magnified-menu-bar tour was developed with owned, bounded example fixtures on an Apple M4 / macOS 27.2 host. Light/dark and solid fallback galleries supplement the layout and preference-path tests. This work deliberately does not refresh the historical release validation receipt: the coordinator must run the final-tree complete local gate before release. Native macOS 14/15, Intel, login approval and notification/location permission flows remain separate runtime checks. No app was installed and no permission was requested by the tour fixtures.

## Menu bar click routing candidate — 0.37.1 (73)

Combined-item routing and one-click dropdown switching have pure calculation and owned-window event/render fixtures that drive the real AppDelegate/PopoverInteraction entry points. Fix 1 covers event-source eligibility, handling-time screen coordinates, close-in-flight reopening and diagnostic close accounting; an environment-only unified-log trace supports manual real-click verification (see [Menu Bar](MENU-BAR.md#maintainer-real-click-trace)). The requested scoped validation (strict Swift format, warning-as-error build, selected MenuBar/Popover/StatusItem/Detail/History/Settings tests and gated light/dark evidence) is separate from the complete release gate. Per the task constraint, `scripts/verify-local.sh`, universal packaging, real-collector diagnostics and Release benchmarking were not run for this candidate. No installed app or real menu bar was touched. Native physical clicks, macOS 14/15 and Intel runtime validation remain open; this candidate does not refresh a release-readiness receipt.

## Native split candidate — 0.37.2 (74)

The main window and embedded Settings use a flush 132pt sidebar with a single full-height 1pt divider, including the transparent titlebar band. Owned-window ScreenCaptureKit fixtures in light/dark capture the real MainWindow over a synthetic gradient, plus injected solid accessibility fallbacks, with existing authorization only. Scoped validation consists of strict recursive Swift format lint, a warning-as-error build and the requested Sidebar/Glass/SystemStyle/MainWindow/Detail/Preferences/Navigation tests. This candidate does not refresh the historical release validation receipt. Per the task constraint, `scripts/verify-local.sh`, universal packaging, real-collector diagnostics and Release benchmarking were not run. Physical full-screen transitions, native macOS 14/15 and Intel runtime/appearance validation remain open. No installed app or real menu bar was touched.
