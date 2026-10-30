# Network details

Open **Network** in the detail sidebar. The headline and history show download/upload for one interface. In Settings → **Network interface**, choose **Auto · IPv4 / IPv6 primary route** or a named interface. Changing this preference does not modify macOS network configuration.

## What Auto counts

Auto chooses an existing, locally up IPv4 primary interface first, then the IPv6 primary interface. If neither is available, selected traffic is unavailable. A manual selection keeps the chosen name; missing/down interfaces do not produce invented rates.

Counters include traffic across protocols on that one interface. Auto does not look up routes for each destination, combine both protocol families' primary interfaces, or add tunnel and physical traffic together. Split routes and VPNs may send traffic through other interfaces; select a named interface to inspect its traffic explicitly.

## Local configuration

| Detail | Meaning |
| --- | --- |
| Local IPv4/IPv6 | Observed interface addresses and CIDR prefix lengths where available; IPv6 zones such as `%en0` are preserved |
| IPv6 address state | Link-local/unique-local labels and temporary, deprecated or not-ready state where the OS exposes flags |
| Point-to-point peer | Observed destination address on a point-to-point interface, when present |
| Primary route/router | Configured IPv4/IPv6 primary interface and router, independently of the traffic selection |
| DNS configuration | Configured global/service server addresses; not an authoritative list of the resolvers macOS uses for each query |
| Service name/type | SystemConfiguration's local service label and hardware type, when available |
| MTU and interface flags | Observed packet-size limit and local up/running flags; these do not prove internet access |
| Details checked | Time since the last metadata discovery attempt; metadata is cached between refreshes |

Local metadata discovery makes no internet request and never changes network settings. Separate internet checks default off; Settings → **Internet checks…** independently opts into Apple/custom HTTPS, ipify requests or ICMP to one saved numeric IPv4/IPv6 destination through Save. ICMP has no default destination or hostname lookup and bypasses HTTP proxies. See [Optional internet checks](INTERNET.md#icmp-ping-0320). Complete app-level aggregation and live external/LAN/scoped-IPv6 ping validation remain unfinished. Wi-Fi radio details are described below.

Right-click a detail value row and choose **Copy value** to copy its full value, including long/scoped IPv6 strings. Headings have a disabled action. The menu captures the value when it opens, so a subsequent live refresh cannot make the action copy another row's value.

## Wi-Fi radio

Since 0.12.0, Network details reads current CoreWLAN telemetry for up to eight Wi-Fi interfaces present in the sampled interface inventory. The Wi-Fi section groups each radio by interface and shows its link state, RSSI and noise in dBm, their difference in dB, transmit link rate in Mbps, PHY, channel, band, width and security type where exposed. **Transmit link rate is a negotiated radio rate, not download/upload throughput or an internet speed test.** The radio timestamp is separate from the cached IP/configuration timestamp.

The adapter does not scan nearby networks, join networks or change radio power/configuration. It does not collect SSID, BSSID, country code or hardware addresses and does not request Location permission. Network names/identity and user-authorized location-gated access remain unfinished. The rest of the existing panel can still show SystemConfiguration service names, local IP addresses and configured routers/DNS.

CoreWLAN documents several zero values as errors or no association. Those values are withheld, rather than shown as 0 dBm or 0 Mbps. False power and no-mode results cannot reliably distinguish disabled/disconnected from an API error; the UI explicitly says “Off or unavailable” or “Not associated or unavailable”. Unknown PHY/band/width/security values remain unavailable. There is no fabricated quality percentage, inferred channel width or PHY-based speed estimate. Widths newer than the SDK's public 160 MHz enum are not guessed.

Only the existing shared sample tick schedules a radio refresh, at least five seconds apart. One utility job isolates synchronous native IPC from the sampler, with at most one in flight, no accumulating retries, extra timer or event subscription. A stuck native call does not block the sampler or start overlapping work. Results are tied to the sampled interface name/index/up/running inventory and a lifecycle generation; replacement, pause/sleep, module changes and closure clear the cache. Old jobs cannot republish after a stop/restart. The client is released when an outstanding call returns after closure. Reopening during an outstanding call waits for it to finish. Cache age uses the request-start uptime and values older than 15 seconds are withheld. Visible mode/channel/power changes during a multi-call read invalidate that reading, although the native fields are not an atomic snapshot.

The reader and its queue are not constructed until Network details are opened; one reader is retained afterward to bound outstanding work across repeated openings. Native clients live only for active details periods. No radio values are persisted, graphed or used for alert rules. Public API provenance and exact sentinel semantics are recorded in Wi-Fi research.

## Process traffic

Keep **Network** details open and choose **Processes** (the default) or **Apps** in the compact selector at the trailing end of the **Process traffic / App traffic** card header. The same selector lives in CPU/Memory’s **Top processes / Top apps** header, including All readings. The graphical summary ranks rows by combined receive/send rate and fits more rows as the persistent window grows, up to the existing eight-row output limit; **All readings** shows up to eight and the full scope/accounting explanation. Ownership uses the PID and kernel unique ID together, so a reused PID cannot inherit an earlier process's counters. Rates require two complete queries: the first establishes a baseline; the second can produce rates. The panel reports accounting state, with counter age and socket count after a query completes. One shared choice persists across CPU, Memory and Network and reopening; changing modes clears old output and starts a fresh interval. Unrelated Settings edits preserve the choice.

These are **socket bytes across all interfaces, including loopback**. They are independent of Settings → Network interface and the selected-interface headline/history. Socket bytes are not link bytes: protocol overhead, loopback and traffic on other interfaces mean the rows should not be summed to reconcile the headline. Processes keeps individual owners separate. Modern connection providers and QUIC coverage are incomplete in either view; bundle grouping does not establish full per-app traffic parity.

### What Apps groups

Apps sums valid per-owner rates from the complete bounded ledger (up to 1,024 owners) before taking the top eight groups. It never sums a previously truncated top-eight process list or calculates rates from changing aggregate app totals. The displayed process count reports distinct owner identities with positive bytes during that completed interval, not all running helpers. Valid idle owners are omitted from this view; a ready empty list means no active traffic within the available kernel TCP/UDP coverage, not no traffic on the Mac.

Membership comes from the current executable path under the outermost lowercase `.app/Contents/` component. Nested helpers/apps group into that outer bundle; for example, Simulator inside Xcode groups under Xcode. Different path strings remain separate without resolving symlinks, case or volume aliases. Different bundles can therefore have identical displayed names. Missing/unresolved/exited/identity-changed paths stay separate PID rows; names and parent PIDs are never used to guess membership. Shared WebKit/system brokers are not assigned to the apps that requested their work.

Kernel unique identity and exec-version checks bracket each path lookup, but this observes the executable now; it cannot prove the byte-producing image throughout an interval spanning exec. The top-eight bundle paths reach the UI for local icons and path tooltips/accessibility. Paths are never saved or logged. This is executable-path grouping, not delegated network responsibility. Research and evidence retain the exact private-ABI guards, fallback rules and unverified runtime paths.

Only verified complete intervals produce numeric process rates. A valid idle interval can be zero; failed, unknown, missing, overflowing or reset intervals have no numeric rate and rebuild fresh baselines. Missing updates reopen the inventory after five seconds. Hard failures, including unrecognized layouts or exceeded capacity, close the stream and retry after 60 seconds while Network details remain selected. Pausing, sleeping, hiding details or selecting another module stops collection and clears its state; reopening requires warm-up again.

Collection shares the existing serial sampler and uses one dispatch read source, with no additional timer, subprocess or external requests. Network details skip the unrelated general CPU/memory/disk process scan and clear those process baselines on entry; other detail pages retain their existing sampling. Each drain is limited to 32 datagrams or about 2 ms before yielding. Bounds are 8,192 socket sources, 1,024 owners, eight process rows or bundle groups (summary rows depend on available height, up to eight), a requested 256 KiB kernel receive buffer and a 64 KiB raw scratch buffer. Only Apps requests the full worker-local owner projection; default process/helper output stays at eight. Exceeding the ledger bound invalidates the interval rather than silently displaying truncated sums. Endpoint addresses/ports are not decoded, logged or retained. Raw scratch bytes are cleared immediately after each decode, including failed decodes.

Each positive owner needs at most three guarded kernel identity/path calls per new ready snapshot, sharing one 4,096-byte scratch buffer. The worker makes no filesystem metadata reads, icon lookup or NSWorkspace IPC and retains no identity/path cache beyond the existing top-eight snapshot projection. A detail-lifetime, main-actor FIFO cache holds display names/icons for at most 32 displayed bundle paths; only drawn summary rows or realized table cells request metadata/NSWorkspace icons. Repeated reads of an unchanged ready snapshot reuse its eight display rows. Stop/close/pause/module or mode changes clear grouped accounting; revision checks reject stale/ABA deliveries. The API microbenchmark repeats one owned process and does not establish cost for 1,024 distinct live owners or long-run churn.

## Refresh, bounds and missing data

Traffic counters use the shared sampler cadence. Address/service discovery is cached separately, bounded to 128 interfaces and eight addresses per interface; the panel explicitly marks address truncation. It preserves IPv6 scope, valid prefixes and available address-state flags without running a subprocess.

SystemConfiguration callbacks only set an atomic invalidation flag on the existing worker queue. A notification or interface name/index/up/running change triggers discovery at the next shared tick. A 30-second fallback covers missed notifications. There is no additional polling timer or queue of discovery jobs.

A failed discovery clears the affected cached data instead of keeping stale addresses. A successful empty result is distinct from unavailable data. Cached addresses must match both interface name and index; replacement restarts pending network-rule holds even when the name is reused. Pause/Resume resets rate baselines and refreshes metadata, so the first resumed rate is unavailable and Details checked starts at zero seconds. [Alert rules](ALERTS.md) describes local interface-state and traffic conditions.

## Development and evidence

Open the exact panel without manual navigation:

```sh
build/TinyStats.app/Contents/MacOS/TinyStats --preview --preview-module network
```

Run explicit local radio diagnostics without scanning or collecting network names:

```sh
build/TinyStats.app/Contents/MacOS/TinyStats --diagnose --wifi
```

Default diagnostics do not instantiate the radio reader. Measure the Network workload with the existing harness:

```sh
python3 scripts/benchmark-app.py --preview --module network --warmup 15 --duration 60
```

For the Apps workload, use `python3 scripts/benchmark-app.py --popover --module network --network-bundles --theme dark --warmup 30 --duration 60`. Omit `--network-bundles` for Processes, or add `--after-close` for automatic dismissal during warm-up. The flag requires Network details in preview/popover/after-close mode; it only seeds the owned benchmark preferences. The recorded 0.27.0 open/control workloads additionally use two owned loopback senders. No external test request is generated.

The opt-in native loopback fixture can be run locally without external traffic:

```sh
TINYSTATS_VALIDATE_TRAFFIC=1 swift test --build-system native --filter liveKernelTrafficAccountsOnlyOwnedLoopbackPayloadAndFinalCounters
```

For 0.7.0, this fixture passed with output filtered to the test's own process after complete unfiltered accounting: 4,096 bytes sent before the baseline were excluded; 2,048 active TCP bytes were counted in each direction; 1,024 TCP bytes from a socket opened and closed entirely between polls were retained; and 256 bytes from closed UDP sockets were counted. This validates the owned loopback cases, not modern-provider/QUIC coverage or full application aggregation.

Copy-menu enabled/disabled states were checked without changing the clipboard. Pause/Resume behavior was exercised; no OS network configuration was modified.

IPv6-only Auto fallback is covered by fixtures; the available host has no IPv6 primary route. Live IPv6-only/VPN/hot-plug cases and representative hardware remain unverified. These establish local costs and scoped checks, not the missing network capabilities.

The process-traffic adapter is independently written from public kernel protocol declarations; see [Third-party notices](../THIRD_PARTY_NOTICES.md) for the XNU sources.

## Opt-in internet observations (0.9.0)

Apple HTTPS response/time and ipify IPv4/IPv6 discovery are separate from local configuration, selected-interface bytes and kernel process counters. Both request types start off. Settings → Internet checks discloses destinations, cadence and source-IP visibility before enablement. Enabled checks continue with details closed; pause/sleep and opt-out cancel them. Results follow the OS route/proxy/VPN, rather than the selected interface. See [Optional internet checks](INTERNET.md) for exact semantics, bounds, rules, reproduction and remaining gaps.
