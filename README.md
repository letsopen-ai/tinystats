<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo-dark.svg">
    <img src="docs/brand/logo.svg" width="360" alt="tinyStats">
  </picture>
</p>

<p align="center">
  <strong>A tiny, native macOS menu bar system monitor.</strong><br>
  CPU, GPU, memory, disks, network, sensors, battery and weather — one click away.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-6E7781?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/AppKit-native-1F6FEB" alt="Native AppKit">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2EA043" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#development">Development</a> ·
  <a href="docs/ROADMAP.md">Roadmap</a>
</p>

<p align="center">
  <img src="docs/images/overview.jpg" width="760" alt="tinyStats Overview window showing CPU, GPU, memory, startup disk, network and system readings">
</p>

## What is tinyStats?

tinyStats puts live readings from your Mac into the menu bar — CPU and GPU load, memory pressure, disk and network throughput, temperatures, fans and battery — and opens a detail window with history and the processes behind each number when you click it. It is written in Swift and AppKit with no third-party runtime dependencies, samples everything on one shared timer that slows down in Low Power Mode, and keeps your data on your Mac: no account, no analytics, and nothing leaves your Mac unless you turn on one of the optional network features (weather and internet checks).

It is an early-stage, MIT-licensed project working toward a lean, open alternative to commercial menu bar monitors.

## Features

| Module | What you get |
| --- | --- |
| 🧠 **CPU** | Total and per-core usage with efficiency/performance core grouping, load averages, uptime, top processes and Apple Silicon cluster frequencies |
| 🎮 **GPU** | Utilization, model and memory, plus frequency and model-power readings where supported |
| 🧮 **Memory** | Composition, OS memory pressure, swap and top processes by footprint |
| 💽 **Disks** | Volume capacity, read/write rates, per-process I/O and read-only NVMe/ATA SMART health |
| 🌐 **Network** | Interface traffic, addresses, routes, DNS, Wi-Fi radio details and partial per-process traffic from kernel TCP/UDP statistics |
| 🌡️ **Sensors** | Temperatures, fan speeds, watts, volts and amps, with a searchable sensor browser and live chart (read-only) |
| 🔋 **Power** | Internal battery, connected accessories, energy mode and available power readings |
| 🕑 **Time** | Month calendar, named world clocks, custom menu bar clocks and an optional calendar agenda |
| ⛅ **Weather** | Opt-in forecasts from MET Norway: temperature, conditions, precipitation, wind, sunrise and sunset |
| 📈 **History** | Up to 28 days of local numeric history with peak/average/minimum views, a per-core heatmap and CSV export |
| 🔔 **Alerts** | Opt-in notification rules for usage, pressure, throughput, sensors, battery, thermal state, SMART and more |
| 🎛️ **Menu bar** | Pick any readouts and give each one of 14 styles — text, value or icon only, history graphs, gauges, pie, ring, per-core bars or a battery icon |

A six-step welcome tour on first launch helps you choose your menu bar readouts. Readings that your hardware does not expose are shown as unavailable rather than guessed.

<table>
  <tr>
    <td width="50%"><img src="docs/images/cpu.jpg" alt="CPU page with per-core usage, E/P cores, top processes and cooling"></td>
    <td width="50%"><img src="docs/images/sensors.jpg" alt="Sensors page with a searchable list of temperature sensors and a live chart"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>CPU</b> — per-core load, E/P cores and top processes</sub></td>
    <td align="center"><sub><b>Sensors</b> — searchable, read-only sensor browser</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/history.jpg" alt="History window showing recorded CPU peaks and a per-core heatmap"></td>
    <td><img src="docs/images/menu-bar-settings.jpg" alt="Menu Bar settings choosing which metrics appear and in which style"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>History</b> — up to 28 days, with CSV export</sub></td>
    <td align="center"><sub><b>Menu bar</b> — choose readouts and styles</sub></td>
  </tr>
</table>

<sub>The CPU capture uses synthetic fixture data; the others are native captures on an Apple Silicon (M4) Mac.</sub>

## Requirements

- macOS 14 Sonoma or newer
- Apple Silicon is the primary target; the universal build also runs on Intel, which has had less testing
- To build: Xcode 16 or newer (Swift 6 toolchain); Python 3 for `scripts/verify-local.sh` and benchmarks

## Install

> **Signed builds are coming soon.** For now, tinyStats is built from source.

```sh
git clone https://github.com/letsopen-ai/tinystats.git
cd tinystats
scripts/build-app.sh --universal
open build/TinyStats.app
```

The build produces `build/TinyStats.app` (and a `build/TinyStats.zip`). Drag `TinyStats.app` into `/Applications` to keep it.

### First launch

- tinyStats lives in the menu bar and has no Dock icon. **Click** a readout to open its page; **right-click** for options such as Pause, Settings and the welcome tour.
- Local builds are ad-hoc signed, not notarized. A build you made on the same Mac normally opens directly. If you copy it to another Mac and Gatekeeper blocks it, **Control-click the app → Open**, or use **System Settings → Privacy & Security → Open Anyway**. Please don't disable Gatekeeper system-wide.
- To start at login, enable **Launch at login** in **Settings → General**.

### Uninstall

1. Turn off **Launch at login** in Settings → General, then quit tinyStats.
2. Delete `TinyStats.app`.
3. Optionally remove saved history and settings:

   ```sh
   rm -rf ~/Library/Application\ Support/TinyStatsHistory
   defaults delete com.niechen.tinystats
   ```

4. Optionally reset its macOS permission grants (location, calendar, notifications): `tccutil reset All com.niechen.tinystats`.

## Privacy

tinyStats is local-first. Monitoring needs no account, and the app contains no analytics, crash reporting or update checks.

| What | Network? | Details |
| --- | --- | --- |
| System monitoring | **No** | All readings come from macOS APIs on your Mac. |
| History | **No** | Saving is **on by default**: up to 28 days of numeric readings only (no process names, addresses or locations) in a private `~/Library/Application Support/TinyStatsHistory` folder that tinyStats asks Time Machine to skip. Turn saving off or clear it in History or Settings → General. [More](docs/HISTORY.md) |
| Weather | Opt-in, **off by default** | Sends rounded coordinates to **MET Norway** (`api.met.no`), which also sees your public IP. Current location requires macOS location permission; a manual city works without it. [More](docs/WEATHER.md) |
| Internet checks | Opt-in, **off by default** | HTTPS checks (Apple preset or your URL), public-IP lookup via ipify and ICMP ping to an address you choose (no default). Each destination sees your IP. [More](docs/INTERNET.md) |
| Calendar agenda | Opt-in, **off by default** | Read on-device with your permission, only while the Time page is open; never saved or uploaded. [More](docs/CALENDAR.md) |

tinyStats installs no helper tools or system services; the only thing it registers is itself as a login item, and only if you turn on **Launch at login**. Fan readings are strictly read-only — the app never writes fan speeds. An experimental privileged traffic service and fan-control policy exist in the source tree but are unbundled and not enabled; see [Privileged traffic](docs/PRIVILEGED-TRAFFIC.md) and [Fan control](docs/FAN-CONTROL.md).

## Development

```sh
swift test --build-system native   # run the test suite
scripts/build-app.sh --universal    # build build/TinyStats.app
scripts/verify-local.sh             # full check before a pull request
```

`verify-local.sh` runs the tests, strict format lint and warnings, universal packaging, signature checks and diagnostics, with logs in `build/ci`. Useful extras:

```sh
build/TinyStats.app/Contents/MacOS/TinyStats --diagnose             # local capability report, no upload
build/TinyStats.app/Contents/MacOS/TinyStats --diagnose --hardware  # adds frequency/model-power sampling
build/TinyStats.app/Contents/MacOS/TinyStats --preview              # persistent development window
```

The code is split into `Sources/TinyStatsCore` (models, collectors, settings, history), `Sources/CTinyStats` (system API wrappers) and `Sources/TinyStats` (AppKit UI and the sampling worker). Start with [Design](docs/DESIGN.md), [Performance](docs/PERFORMANCE.md) and [Compatibility](docs/COMPATIBILITY.md).

The automatic push/PR [release source checks](docs/SELF_HOSTED_CI.md) checks source metadata and committed local release validation receipts on Ubuntu. Native tests run locally; the M4 only builds/signs/releases. Keep using `verify-local.sh` for the complete required gate.

## Contributing

Bug reports, hardware diagnostics from different Macs, documentation and focused code changes are all welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md), check the [roadmap](docs/ROADMAP.md) for open work, and report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Changes are recorded in the [changelog](CHANGELOG.md).

## Acknowledgements

- [Stats](https://github.com/exelban/stats) by Serhiy Mytrovtsiy (MIT) — SMC and IOReport protocol research. No Stats code or binary is embedded.
- [MET Norway](https://api.met.no/weatherapi/locationforecast/2.0/documentation) — forecast data under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Not an endorsement by MET Norway.
- Apple's open-source [XNU](https://github.com/apple-oss-distributions/xnu) headers (APSL 2.0) — network statistics protocol facts.

Full details are in [Third-party notices](THIRD_PARTY_NOTICES.md). tinyStats is independent of Bjango (iStat Menus), Stats and MET Norway.

## License

[MIT](LICENSE) © 2026 Nie Chen
