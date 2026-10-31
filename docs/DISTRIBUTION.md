# Distribution and release checklist

TinyStats is currently distributed as source. Building from source produces an ad-hoc signed app (see the [README](../README.md#install)). A signed, notarized binary release is a separate milestone tracked by the checklist below.

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

- [ ] Developer ID signing completes unattended and notarization credentials are configured.
- [ ] Build with `TINYSTATS_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh --universal`, submit the ZIP with `xcrun notarytool submit build/TinyStats.zip --keychain-profile <profile> --wait`, staple the app (`xcrun stapler staple build/TinyStats.app`), repackage, and confirm with `spctl --assess --type execute -vv build/TinyStats.app`.
- [ ] `scripts/verify-local.sh` passes on the release commit.
- [ ] Tests and the Release `--diagnose` run pass natively on macOS 14 (arm64), macOS 15 (arm64) and an Intel Mac for the release commit. A universal build compiled on one host is not runtime evidence for other OS versions or architectures; see [Compatibility](COMPATIBILITY.md).
- [ ] Validate the System redesign in light/dark and purple/green/graphite accents, including Overview resize, toolbar actions, sidebar/History navigation, all inset Settings forms, picture styles, Separate/One layout, spacing, switches, Save/Apply/Cancel, authorization actions and unavailable hardware. Offscreen render fixtures are supplementary evidence.
- [ ] Spot-check representative hardware: more than one Apple Silicon generation, a laptop with a battery, and a fan-equipped model.
- [ ] Check sleep/wake, external storage hot-plug, network/VPN switching, notched menu bars, Light/Dark appearance (including a light menu bar), launch at login and notification permission denial.
- [ ] Review the known gaps in the [roadmap](ROADMAP.md) and decide which are acceptable for the release.
- [ ] Reproduce the [performance](PERFORMANCE.md) measurements on representative hardware.
- [ ] Publish checksums and installation instructions with the release; add a Homebrew cask once a stable signed download URL exists.
