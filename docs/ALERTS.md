# Alert rules

Open Settings → Edit alert rules. Add a rule, choose its metric and source, set the condition, then Save changes. New rules start disabled. Cancel or closing the editor discards the whole draft. Invalid fields remain visible and block saving or switching away. Editing rules does not request permission or enable notifications; the separate Enable notifications switch does that.

Each rule has a name, inclusive ≥/≤ or equality comparison, threshold, minimum sustained duration, cooldown, repeat/once-per-episode choice and optional sound. Duration is 0–86400 seconds; cooldown is 30–86400 seconds. Up to 32 rules are retained. Notification presentation style is controlled by macOS for TinyStats.

## Metrics and sources

| Metric | Threshold / source |
| --- | --- |
| CPU / GPU usage | Percent of machine / GPU capacity; any GPU or GPUs with a chosen model name |
| Memory usage / pressure | Working-set percent, or Normal/Warning/Critical kernel pressure |
| Volume used space | Percent; any local volume or a chosen mount path |
| Physical disk reads / writes | MiB/s across the physical devices already sampled |
| Network upload / download | MiB/s; the selected interface or a named interface |
| Network interface state | Up/Down for an observed interface; a missing interface is unavailable. This is not an internet connectivity test |
| Sensor | Hottest recognized CPU temperature, an explicit discovered SMC key, or an available IOReport model-power sensor, with Celsius/RPM/W/V/A units. Temperature thresholds remain Celsius regardless of display preference |
| Battery level / power | Percent, optionally only while on battery; signed watts, negative when discharging |
| Power source | On battery / external power; unavailable on machines without an internal battery reading |
| Thermal state | Nominal/Fair/Serious/Critical OS state |
| SMART warning | Any drive or one with a stable device-reported identifier; requires disk details open or the separate five-minute background health option |

Network rules reuse one selected or named interface's counters across protocols. In Auto mode, the selected source prefers an existing/up IPv4 primary interface, then IPv6; it does not combine both. Interface name and runtime index identify observations, so replacement at the same name restarts a pending duration. Up/Down uses the interface's local up flag and does not establish internet access. Addresses, configured DNS and routers are informational, not additional rule signals. See [Network details](NETWORK.md).

Interface state, power source and SMART warning conditions use Equals. Memory pressure and thermal state also support ordered ≥/≤ comparisons.

The 0.4.0 model-power sources use canonical keys `ioreport:cpu`, `ioreport:gpu`, `ioreport:ane` and `ioreport:dram`, accepted only as power in watts. In the editor, choose **Sensor reading** and an available model-power source. A channel is unavailable until an actual energy increment is observed; fixed CPU energy placeholders do not create zero-watt rules. GPU watts have been checked on the available M4; other model-power channels and hardware still require runtime validation. Active frequencies are displayed in details and are not a standalone rule metric.

GPU model selectors survive reboot and intentionally cover all GPUs of that model. Runtime registry IDs distinguish devices while a condition is being held. Volume filesystem IDs restart holds when a replacement appears at the same path. SMART selectors use a local SHA-256 of product name and reported serial; raw serials remain within the C adapter and are not placed in models, preferences, diagnostics or uploads. Drives without a usable stable identifier can participate in Any drive rules.

## Timing and unavailable data

Rules reuse the single sampler and its cadence; evaluation adds no process scan, timer or subprocess, and never enables internet requests. Internet observations require their separate explicit opt-ins. A condition must be observed throughout its duration, and fires on the next eligible sample. Sensor/battery cache entries expire for rules after 15 seconds; volume entries after 60 seconds; SMART entries after 330 seconds. Unsupported or nonfinite readings never become zero.

For an Any source rule, matching sources are considered deterministically, retaining the held source while it still matches. A source change restarts the duration. Missing data clears the pending duration but preserves a fired once-per-episode latch; another device's normal reading does not invent recovery. An observed false condition rearms the episode. Repeating rules may fire again after their cooldown. SMART additionally requires a distinct fresh observation for each notification.

Editing/disabling a rule, toggling the master switch, pause and sleep reset pending conditions while retaining cooldowns for the same rule IDs. Removing a rule removes its state. Cooldowns are in-memory session state. A queued notification is checked against the current master switch and exact saved rule before delivery, so disabling or editing a rule suppresses its queued events.

Five legacy defaults migrate: sustained high CPU, critical memory pressure, low volume space, low draining battery and SMART warning. Individual malformed/future rules are skipped without resetting valid neighbors or other preferences. An explicitly empty rule list stays empty.

OS notification authorization, presentation, sound and Focus behavior depend on the user's system settings. The native editor and pure rule engine are exercised; actual notification permission and banner/sound delivery are not claimed as validated by the unit tests.

Competitive reference: [Bjango's rules guide](https://bjango.com/help/istatmenus7/rules/). TinyStats uses one native notification identity; it does not copy the helper-based presentation mechanism described there.

## Optional internet observations (0.9.0)

Three metrics require the corresponding Internet checks opt-in: HTTPS response state, full HTTPS response time (ms), and observed public-IP change for IPv4 or IPv6. HTTPS rules follow the configured Apple preset or custom URL/status, including rules saved before 0.26.0; changing that configuration starts a fresh hold and rejects queued results/alerts for the old destination. A response is endpoint-specific, not proof of universal online/offline status, and response time is not ICMP ping. HTTPS results must be no older than 90 seconds; IP results no older than 330 seconds. Public-IP changes compare successful provider responses, never trigger on the first baseline, use zero duration and notify at most once per observation subject to cooldown. A new observation rearms independently. Notifications do not include the actual address. Delivery rechecks opt-in, destination and lifecycle revision, so queued pre-disable/pre-pause events are discarded. See [Internet checks](INTERNET.md) for privacy, requests and limits.

Weather rules use the chosen location’s fresh model forecasts: temperature in Celsius, wind in m/s and precipitation for an actual next-1h interval in mm. The global Fahrenheit choice changes presentation only. Weather opt-in and master notification opt-in are separate; queued delivery rechecks enabled state, configuration revision and freshness deadline. Wider precipitation periods are unavailable for a next-hour rule. See WEATHER.md for data interpretation and limitations.
