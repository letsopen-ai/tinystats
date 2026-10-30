# Roadmap

TinyStats is an early-stage project working toward a lean, native alternative to commercial macOS menu bar monitors such as iStat Menus. Full feature parity is a goal, not a current claim. Contributions are welcome through [feature branches and PRs](../CONTRIBUTING.md); see the [changelog](../CHANGELOG.md) for what each version added.

## What works today

- Native CPU, GPU, memory, disk, network, sensor, battery and time monitoring with bounded history, top CPU/memory/disk processes, per-metric menu bar styles (text, graphs, gauges, custom clocks), pause and power-aware cadence.
- A resizable main window with detail pages, a searchable sensor browser, and a History window with numeric CSV export and optional bounded local checkpoints across restarts.
- World clocks and custom menu bar clocks; optional Calendar agenda.
- Read-only NVMe SMART health and ATA threshold status, Apple Silicon CPU-cluster/GPU frequencies and optional model-power sensors.
- Local network details (addresses, routes, DNS, Wi-Fi radio data) and kernel TCP/UDP per-process traffic with executable-bundle grouping. CPU/Memory now share the Processes / Apps section-header choice and aggregate before ranking; see [Components](COMPONENTS.md#cpu-memory-and-network-process-grouping).
- Opt-in alert rules, opt-in Internet checks (HTTPS, public IP, ICMP ping) and opt-in MET Norway Weather. Weather is off by default for new installs and current location requires OS permission.

## System redesign validation

- Shared System tokens, accent menu graphics and platter dropdowns are implemented. Overview now uses the approved device/state header, value platters, segmented memory/storage and a five-minute network trace.
- Step 3 is implemented: inset grouped forms across General/Menu Bar and all existing feature editors, native switches, picture presets and an appearance-aware preview strip. History and Welcome reuse the shared neutral tokens. Settings render fixtures cover light/dark; no fan-control pane is introduced.
- Process grouping has light/dark dropdown/window/readings fixtures and native keyboard regressions. Real process-churn Release cost and native macOS 14/15/Intel validation remain open; [Performance](PERFORMANCE.md#process-app-grouping-cost-and-bounds) gives operation-count estimates only.
- Before release, complete the full final-tree local gate and native light/dark, non-blue accent, resize and physical input checks; offscreen fixture renders do not replace those checks.

## Before a signed public release

See the [distribution checklist](DISTRIBUTION.md). The main open items are:

- Measure and reduce native UI memory overhead; record real costs on current and minimum supported macOS ([Performance](PERFORMANCE.md)).
- Re-run the current source natively on macOS 14/15 (Apple Silicon) and an Intel Mac, then extend coverage to physical Intel sensors/GPU, more chip generations, laptops with batteries, external storage and multiple GPU drivers ([Compatibility](COMPATIBILITY.md)).
- Validate raw sensor descriptions per hardware family. Unknown keys must remain identifiable rather than given misleading labels.
- Improve recovery when menu bar space is constrained; validate readout order and compact graph sizing.
- Add fixture-driven system adapters for driver failure and hot-plug tests.
- Exercise IPv6-only primary routing, VPN/service changes and network hot-plug on representative hardware.

## Deeper coverage

- Broaden CPU/GPU active-frequency and model-power support beyond the Apple M4 paths validated so far; establish actual CPU/Neural Engine/DRAM energy availability, without a continuous `powermetrics` subprocess.
- Finish the unbundled modern-traffic service (see [Privileged traffic](PRIVILEGED-TRAFFIC.md)): app opt-in, registration/removal and signed-root validation. It is not installed or enabled today.
- Extend process traffic accounting to modern connection/QUIC providers and whole-application attribution, using an opt-in privileged path only where required. Keep costs measured and inventory/rate handling fail-closed.
- Continue Internet-check validation (external/LAN/scoped-IPv6 ICMP, permission transitions, VPN/route/sleep behavior, live IPv6) and Wi-Fi coverage (SSID/BSSID access, 2.4/6 GHz, older hardware, roaming). See [Internet checks](INTERNET.md) and [Network](NETWORK.md).
- Broaden SMART compatibility with real ATA and external bridge enclosures; NVMe validation so far covers an internal Apple SSD only.
- Fan control: the isolated policy core exists, but raise-only semantics, ownership-aware recovery, the privileged boundary, controls and hardware validation are still required. The collector is strictly read-only and no fan-control feature is enabled. See [Fan control](FAN-CONTROL.md).
- AirPods-specific charge sources beyond HID devices.
- Weather: place lookup, additional providers, optional UV/moon information and advisories; long-run refresh and proxy/VPN/sleep validation. See [Weather](WEATHER.md).
- Calendar: permission transitions, live account reads, recurring/declined events and account changes. See [Calendar](CALENDAR.md).
- Rules: broader weather/event signals; validate notification permission, banners and sound. See [Alerts](ALERTS.md).
- History: per-device and GPU-core history, denser comparisons and accessibility improvements. See [History](HISTORY.md).
- Individual GPU-core activity is not currently available from public APIs.

These are explicit gaps. Local core monitoring is available now; full commercial feature parity is not claimed.
