# Changelog

All notable changes to TinyStats. Versions marked "preview" were development builds and were not published as binaries.

## Unreleased

- Aligned the greet slogan with the welcome heading beside the app icon and lightened it to 18pt medium primary text. Version 0.36.8 (71).

- Strengthened the greet slogan with larger semibold primary text and tighter heading spacing. Version 0.36.7 (70).

- Redesigned all six welcome steps with a menu bar hero, candy module glyphs and visual choice cards; preserved immediate choices, opt-ins and replay. Version 0.36.6 (69).

- Prepare version 0.36.5 (68): run signed, notarized GitHub Releases on the dedicated organization M4 release runner using job-scoped credentials.
- Preserve the footer logo optical weight and paper margin across the M4 rendering checks.

- Extend the main window sidebar beneath the traffic lights, hide the redundant system title, align subsection headings with icons and emphasize only the selected navigation item. Use native unified traffic-light spacing, align page titles with the brand through a shared top inset, keep full-screen geometry within its own window, honour title-band double-click preferences and preserve the previous 884×692 minimum outer size. Preview version 0.36.4 (67).

- Match the dropdown logo’s optical weight to its neighbouring icons; verify footer tooltips and VoiceOver labels in every module/state and add matching help to Weather and calendar actions. Preview version 0.36.3 (66).

- Fix the upside-down dropdown logo; verify footer, Overview and Welcome orientation against the source artwork. Put the Menu Bar preview beside Layout in one compact row, remove the Spacing setting and always use 0pt side padding / 1pt gaps. Ignore obsolete saved spacing values and omit the key on save. Preview version 0.36.2 (65).

- Add Separate / One menu bar layout and saved spacing without changing module styles; place the TinyStats logo first in dropdown footers. Preview version 0.36.1 (64).

- Replace module display-style text menus with accessible production-renderer picture tiles, including Battery power states and the welcome tour. Preview examples follow appearance and font settings; compact the bottom Battery/Clock actions into one row. Bump the preview to 0.36.0 (63).

- Add appearance-aware candy module identity palettes to existing glyphs, charts and meters. Separate the light CPU/GPU companions from GPU/Sensors primaries and warm light Disk to marigold, preserving the existing contrast and series-separation guards. Use a neutral 10% label-colour sidebar selection and module-coloured footer icon hover and paused Play. Keep status-item text and graphics monochrome, including CPU efficiency/performance core bars: efficiency uses 50% opacity and core-kind boundaries gain a 2pt gap. Native controls retain the system accent; text and semantic states retain their existing colours.

- Make macOS 26+ glass more transparent: dropdown wash 60% light / 70% dark, sidebar 55% / 65%, and native grouped chips at 0% extra wash (previously inherited the sidebar wash). Compose inset cards with 2.5% light label-colour / 24% dark window-background tints to preserve backdrop hue without seams; strengthen glass-only secondary ink. Preserve legacy and accessibility fallback fills and native control accents; retain measured module palette ink while darkening unmeasured system/custom light-glass secondary traces and matching legend marks/meters for contrast, and recompute the scroll fade when accessibility treatment changes.
- Centre Sensors labels through titleRect, size rows from font metrics, verify 12pt glyph padding and align window rows with the title. Anchor Apps counts beside a measured value column (76pt minimum), give Overview Memory's caption a 6pt bar gap, and verify native appearance-inheriting Menu Bar switches.

- Extend native Liquid Glass to macOS 26+: one dropdown panel behind neutral inset cards and its icon-only footer, a glass sidebar in Overview/monitoring/Settings, and container-grouped Menu Bar drag chips. Keep chart/number cards and forms neutral, preserve native control accents and macOS 14–25 materials, strengthen the dark wash, and switch every new surface to semantic solid fills for Reduce Transparency or Increase Contrast while open.

- Mark partial app CPU totals with ≥, fit four-digit process counts, remove artificial icon rims and cache the placeholder. Make Network’s Partial coverage note and Sensors counts legible, deduplicate the selected hottest sensor and chart captions, space Overview status columns and hide empty chart grids. Overflow rows name All readings only where available. Group live CPU/Memory immediately through the existing worker schedule, preserve pause/sleep/Network state, expose privacy/cadence in a dedicated nonvisual static-text accessibility element, and refresh appearance-dependent cells without disturbing the grouping header.

- Keep app CPU totals ranked when a helper has no reading, disclose unmeasured membership, preserve Network state on CPU/Memory grouping changes, and retain grouping keyboard focus across refreshes. Align app/broker rows and count columns; restore a visible Sensors scan-cap warning, concise paused headers and dropdown privacy accessibility information. Simplify chart/Sensors captions and empty states, fit power tiles to content and protect scrolling card edges while retaining the icon-only footer.

- Simplify every dropdown to an icon-only footer and reclaim caption/fade space. Move privacy, cadence, sample cost and paused state to About this sample and accessible Pause/Resume help. Remove duplicate headline values, repeated physical-sensor rows and explanatory captions; retain scope caveats in hover/VoiceOver and All readings, visible partial traffic status, and Weather opt-in disclosures.

- Add app-bundle grouping to CPU and Memory, aggregating the full existing process scan before ranking. Share the saved Processes / Apps choice with Network through a compact section-header selector in Summary and All readings. Show bounded cached app icons/names and process counts; disclose that summed memory footprints can double-count shared pages. Preserve existing Network choices without a new preference key.

- Add the TinyStats logo, "Lowercase t.": a paper app icon with a square-cut lowercase t and a mint full stop, with dedicated pixel-snapped 16 and 32 px masters (a solid L-turn foot at 16 px), and a `tinyStats` wordmark with lowercase grey "tiny" and bold "Stats" in New York (SF Pro Rounded alternate documented). Show the icon in the welcome tour header. Commit the iconset, `TinyStats.icns`, light/dark lockup SVGs, icon SVG, social preview and [brand notes](docs/brand/README.md); builds copy the committed icon, regenerated by `scripts/generate-brand.sh`. Replaces the earlier Readout T mark.

- Polish the six-step welcome tour: name default readouts, offer curated starters with Simple text / Compact bars presets and a Combined placeholder preview, introduce modules with short cards and a collapsed More modules… disclosure, and link directly to Overview and Menu Bar settings. Clarify Weather’s MET Norway opt-in, history storage and click/right-click navigation; preserve saved choices.

- Group Internet checks and Calendar settings under a collapsed, session-only Online & Time advanced section in General. Keep Weather primary in the welcome Online step and label Internet checks as advanced. Clarify the optional advanced, default-off agenda/checks in setup and docs; preserve opt-ins, permission routing and Weather’s lifecycle.

- Move Sensors under ADVANCED while preserving ⌘7 and readout order. Default to a named Summary with hottest CPU/GPU charts and grouped unnamed counts; All readings and search expose raw keys. Follow the available menu bar sensor on first focus without changing it. Preserve unavailable readings, chart gaps and existing collection/history bounds.

- Adapt menu bar text, gauge/clock graphics and metric/core colors to the native bar appearance: darker colors on light bars, unchanged colors and text shadow on dark bars. Refresh on appearance changes without wallpaper sampling or a background plate.
- Clarify first-launch and unavailable-reading messages, sensor summaries and the General privacy line without changing collection or saved preferences.
- Default Weather and its menu readout off on new installs. Forecast/location requests require explicit enablement; preserve existing users’ saved Weather choices. Upgraders who relied only on the old in-memory default without saving settings or explicitly enabling Weather will now see Weather off, including those who only granted location permission.
- Add a six-step native first-launch welcome tour with live menu bar choices, module/privacy guidance, local history control, existing optional-feature setup and launch at login. Existing profiles with saved settings silently record the welcome flag without showing the tour. Skip preserves choices; reopen with Show welcome tour. Include an isolated onboarding preview for captures.
- Correct the History checkpoint limit shown in the tour and Settings to 8.2 MiB (8,621,920 bytes), and refresh the Settings login checkbox after returning from the tour.

## 0.35.5 — 2026-10-27 (preview)

- Switch an open menu bar popover to the clicked readout immediately instead of letting automatic outside-click dismissal consume the first click. Clicking the current readout still closes it.
- Preserve outside-click, Escape and app-switch dismissal with handlers that exist only while the popover is open and are removed when it closes or becomes the persistent Settings window. Text editors retain Escape for search cancellation and marked text.
- Native AX routing is checked; the physical mouse-down regression remains unverified.

## 0.35.4 — 2026-10-26 (preview)

- Tighten menu bar side padding to one point and shared-clock spacing to three points. Keep Network arrows at the leading edge so short rates do not create an apparent gap; numeric fields remain fixed-width.
- Let History graphs use added window height and keep Export aligned to the right. Resizing reuses the existing plot samples, and chart inspection uses singular/plural bucket counts.

## 0.35.3 — 2026-10-26 (preview)

- Make menu bar labels, values and missing-reading marks white with a subtle dark shadow; reserve automatic metric/core colors for graphics, with brighter CPU/Network blue and white gauge outlines.
- Halve the app-added side padding and spacing while preserving fixed-width Network rates, complete values and native item routing.
- Keep custom clock graphics white and clarify the settings preview.

## 0.35.2 — 2026-10-26 (preview)

- Respect locale/hour-cycle preferences and the selected forecast time zone across Weather labels and numerical chart inspection; preserve fractional-offset minutes and DST instants.
- Add compass north/cardinal references and space compact forecast labels so 12-hour values remain readable.

## 0.35.1 — 2026-10-26 (preview)

- Avoid deriving a new color for every CPU History heatmap cell. Resolve each row's source color once while preserving its exact color space, opacity, missing markers and gap strokes.
- Retain paired rendering and component allocation evidence. The recurring large History footprint swing and original resource targets remain unresolved; no whole-app RAM saving is claimed.

## 0.35.0 — 2026-10-26 (preview)

- Open Sensors directly to a searchable list. Select a sensor for its current value and bounded recent history, independently of the menu bar sensor; preserve missing readings and temperature units.
- Put component temperature and readable fan speeds together on CPU/GPU, and give history charts more room in the taller detail popover.
- Add labeled vertical menu bar gauges and automatic metric colors. Give every readout its own native item and destination page, replacing coordinate-based combined routing; use macOS ⌘-drag to reorder.
- Keep physical GPU-core activity explicitly unavailable. Recent sensor browsing is view-local, with no extra timer or polling; no app-memory saving or full-parity claim.

## 0.34.0 — 2026-10-25 (preview)

- Add estimated sunrise, sunset and daylight duration beside the Weather daily forecast, with a daylight track and numerical hover times in the selected location's time zone.
- Calculate daylight locally on the existing update path, without another request, timer or saved history. Handle daylight-saving days, fractional offsets, polar day/night and very short intervals near civil midnight.
- Keep daylight independent of forecast freshness while respecting Weather Off, pause and missing location. Show the same numerical estimates in All readings, and clarify waiting-for-location/forecast states there.
- Moon information, broader hardware/platform validation, full parity and original resource budgets remain open; no memory-saving or navigation-accuracy claim.

## 0.33.6 — 2026-10-25 (preview)

- Show reported Metal GPU time by creating process on the GPU page, with relative bars and milliseconds per wall second. This driver time is separate from device utilization and physical-core load; completion bursts can exceed 1000 ms/s.
- Resolve only reported GPU owners while the GPU page is visible, without a full process scan or another timer. Bound client state and withhold missing, changing or reset intervals; preserve zero and release baselines after leaving the page.
- Keep GPU hardware, engine and cooling readings visible in a denser resizable layout. Physical GPU-core load, broader hardware coverage and original resource budgets remain open.
- Restore already-collected process rows when enlarging a window, even without another sample. Select visible rows during drawing instead of discarding them during layout.

## 0.33.5 — 2026-10-25 (preview)

- Reserve validated per-core array sizes when restoring saved history, avoiding geometric growth and spare retained capacity on some core counts. Keep all readings, statistics, validity checks and checkpoint bytes unchanged.
- Reduce retained allocation in maximum-capacity decoder fixtures; whole-app memory savings and the original resource budgets remain unproven.

## 0.33.4 — 2026-10-25 (preview)

- Reuse bounded immutable text styles when drawing statistics summaries and recorded History. Keep fonts, alignment, truncation and colors current through module and appearance changes.
- Reduce repeated drawing work without caching readings or geometry. Each view retains at most 64 styles; whole-app and retained-memory savings remain unproven.

## 0.33.3 — 2026-10-25 (preview)

- Prepare scalar summary, mini and recorded-History chart time positions once and reuse them for drawing, inspection and accessibility. Keep timestamps, cadence, gaps and the selected domain coherent when data changes; avoid rebuilding temporary timeline arrays on repeated reads.
- Retain the existing graphs, statistics, resize behavior and sampling cadence. Component probes show less allocation and hover work; whole-app and retained-memory savings remain unproven.

## 0.33.2 — 2026-10-25 (preview)

- Compare upcoming forecast precipitation with blue bars beside temperature. Keep period amounts, zero, missing values and tiny positive readings distinct; inspect a column for its forecast interval.
- Clarify Weather sections in light mode and give compact wind-direction labels room beside sea-level pressure. Forecast requests and sampling cadence are unchanged.

## 0.33.1 — 2026-10-25 (preview)

- Avoid redundant formatting and redraw requests for unchanged Weather summaries. Keep time, freshness, location, units and locale changes live through the existing shared sampler.
- Skip redundant hidden table and chart resets on Weather. Sampling, forecasts and history saving are unchanged; whole-app memory savings remain unproven.

## 0.33.0 — 2026-10-25 (preview)

- Open Weather to see a graphical forecast summary: condition icons, temperature, humidity/cloud cover, wind speed and direction, sea-level pressure, upcoming model times with interval precipitation, and daily sampled temperature ranges. Inspect readings for dates and values; use All readings for the full forecast and provider details.
- Keep setup and privacy controls on Weather, with clear off/permission/stale/location-change states. Forecast requests and sampling cadence are unchanged.

## 0.32.4 — 2026-10-25 (preview)

- Keep chart readings under a stationary pointer in sync when scrolling. Rebase the inspection position on native clip-view bounds changes, with scoped observation released on detach; preserve one lazy bubble and add no timer or global event monitor.

## 0.32.3 — 2026-10-25 (preview)

- Build chart columns in timeline order and scan their final values directly, avoiding dictionary sorting and temporary value arrays. Preserve weighted statistics, paired CPU peaks, missing/gap markers and pixel positions without a retained cache. Calculation probes show fewer allocator calls and less CPU work; whole-app memory savings remain unproven.

## 0.32.2 — 2026-10-25 (preview)

- Build CPU core-history columns directly from their numeric buckets, avoiding the temporary plot and mapped input arrays on draw and inspection. Preserve statistics, missing-data markers and pixel positions without a retained layout cache. Release probes show less layout CPU work; whole-app memory savings remain unproven.

## 0.32.1 — 2026-10-25 (preview)

- Size temporary process-record storage from a process-count estimate, with headroom and bounded recollection when full. Keep the original 8,192-record ceiling, names, rates and rankings. This reduces requested scratch storage on smaller inventories; whole-app and retained-memory savings are not established.

## 0.32.0 — 2026-10-25 (preview)

- Seed newly opened detail controllers with the existing snapshot and recent history so switching from Settings to a chart does not briefly show an empty graph.
- Add independently opt-in ICMP echo round-trip measurements to one explicitly chosen numeric IPv4/IPv6 address, with a neutral Network summary and detailed result/age. No default destination or hostname lookup; scoped IPv6 uses an interface name. Requests use native unprivileged sockets, bounded receive work and the shared scheduler.
- Add an atomic Ping draft to the resizable Internet Checks window with destination, cadence, route/proxy and Local Network permission disclosure. Existing HTTPS/public-IP choices remain independent; ping defaults off and stale/canceled results are withheld.

- Invalidate queued ICMP sends synchronously on cancellation, hide disabled invalid-address rows, and accurately label ping-only operation as network checks.

## 0.31.3 — 2026-10-25 (preview)

- Restore saved history with a bounded read buffer instead of holding the whole encoded file beside the decoded archive. Standalone measurements show lower restore-time peak memory; no steady-state app saving is established. Existing formats, safety checks and settings remain compatible.
- Accept Swift Testing’s valid singular-suite completion summary in the local build gate, while continuing to reject interrupted or failed output.

## 0.31.2 — 2026-10-25 (preview)

- Keep responsive detail columns and content frames steady during live updates. Remove legacy fixed-size resets that caused AppKit to resize them again on each sample. The measured open/closed memory costs remain essentially unchanged; resource targets remain open.

## 0.31.1 — 2026-10-25 (preview)

- Keep long CPU-core histories between launches while using bounded temporary memory during saving. Existing v2/v3 checkpoints, numeric readings, atomic replacement and five-minute saving cadence remain compatible. Standalone save measurements and limits are recorded in the performance notes; full-app memory targets remain open.

## 0.31.0 — 2026-10-25 (preview)

- Show numerical values and dates on chart hover, including mini histories and logical-core history, with units, missing readings and grouped statistics. Reuse one native hover bubble without extra timers.
- Open the corresponding page when clicking each combined menu-bar readout, including custom clocks; switch directly between open pages and preserve the same-page toggle.
- Retain logical CPU-core peaks, minima, sample averages and validity counts across all History ranges and launches, sharing the bounded archive and sampler. Keep legacy absence, missing values, gaps and layout changes explicit.
- Compare E/P-colored core history with numbers in a resizable, scrollable History window; combine dense columns without losing peaks, weights or missing markers. Export retained core layouts and statistics in numeric CSV.
- Use compact per-core numeric storage and bounded v3 checkpoints. Per-core files need 0.31 or later; turn saving off before downgrading. The 10-core saturated file is about 1.02 MiB, with an 8.3 MiB maximum at 256 counters; unchanged five-minute cadence. This expands history and is not a memory-saving claim. Full parity, GPU-core data, original resource budgets and native hardware/distribution gates remain open.

## 0.30.0 — 2026-10-25 (preview)

- Resize the persistent main window from its 884×660 minimum and keep its size while switching tabs. Charts, type and the calendar grow with available space; taller process cards show more existing readings, bounded to twelve. Settings forms stay compact.
- Stop hidden/minimized detail and preview work, and detach the controller and root view when the main window closes. Keep the shared sampler and existing collection bounds without another timer.
- Show verified GPU core count prominently while keeping individual shader-core load explicitly unavailable. Count is hardware inventory, not per-core activity; true GPU per-core utilization remains unfinished.
- Require the complete local validation gate before code/build pushes. Native macOS14/15/Intel, original memory budgets and full parity remain open; see validation.

## 0.29.0 — 2026-10-24 (preview)

- Open General or Menu Bar from the bottom Settings group and keep the main window open through focus loss and monitoring-tab changes. Suspend hidden monitoring demand while editing settings.
- Read CPU-only E/P-colored utilization, estimated non-overlapping physical-memory composition and a consolidated Power page. Keep core identities accessible, raw electrical readings available and ambiguous fans shared/unassigned.
- Keep numeric History between launches by default for new/missing preferences, preserving explicit Off and failing closed on malformed explicit values. General and History share the asynchronous storage action.
- Correct Mach-tick conversion for process/self CPU and both benchmark samplers. Earlier M4 libproc-based CPU percentages were understated by 125/3; RSS/footprint are unaffected. See the [CPU erratum](docs/PERFORMANCE.md#cpu-measurement-erratum-0290). This corrects units; it is not an optimization.

## 0.28.0 — 2026-10-24 (preview)

- Choose Peak, Sample average or Minimum in History. Weight averages by valid observations when combining buckets and display columns; keep missing readings distinct from zero and show aggregate coverage for older history. No new timer or collector.
- Retain bounded minima/means/counts alongside existing peaks, read v1 checkpoints without inventing older statistics, and append all statistics to CSV while preserving the original columns.
- New checkpoints require 0.28 or later. Turn saving off before downgrading; older apps cannot read the new checkpoint. Off retains it until explicit Clear. Keep all full-parity, original memory, native14/15/Intel, hardware and signed/public-distribution gates open.

## 0.27.0 — 2026-10-24 (preview)

- Group Network socket-owner rates by current app bundle path before ranking, with active member counts, paired bars and a Processes / App bundles selector. Keep unresolved owners and shared services separate; disclose partial kernel TCP/UDP coverage, all-interface/loopback scope and lack of delegated/QUIC attribution.
- Preserve the default process view and eight-row helper contract. Reset accounting on mode changes and reject stale deliveries; keep paths transient, with no filesystem metadata reads, cache, extra timer or network request.
- Verify owned loopback grouping and same-PID exec identity locally. Broader hardware/native14/15, full parity, retained memory and signed/public distribution remain open.

## 0.26.0 — 2026-10-24

- Choose one custom HTTPS health endpoint and expected successful status in Internet checks, with an exact request/expectation preview and atomic Save/Cancel. Apple content verification remains the default preset; all checks remain explicit opt-ins.
- Before downgrading to a pre-0.26 build, disable HTTPS checks: older builds ignore custom destinations and use Apple.
- Reject invalid saved destinations and old endpoint results/alerts, retaining bounded response bodies, shared scheduling and existing request limits.

## 0.25.1 — 2026-10-24 (preview)

- Release expired History buckets as new observations arrive, including after long forward gaps and sparse sampling. Keep partial boundary observations, peak pairing, v1 checkpoint compatibility and fixed capacity. Prevent hidden expired values from surviving in memory and saved checkpoints after the chart has filtered them out.
- Make Off explicitly say saved checkpoints remain until Clear, wrap recovery errors to two lines, and strengthen narrow gap markers without increasing broad gap shading or adding data-line overlays.
- Add isolated synthetic checkpoint seeding and before/after memory snapshots to the resource harness. Keep sample-based app measurements separate from synthetic cost and full physical sleep/28-day validation.

## 0.25.0 — 2026-10-24 (preview)

- Optionally keep bounded numeric History across launches, with default-off local checkpoints, visible storage/errors and confirmed Clear. Off pauses saving and preserves the checkpoint; re-enabling preserves earlier disjoint readings. Keep CPU peaks paired, missing values explicit and restart/clock gaps honest.
- Checkpoint on the shared worker at five-minute intervals and best-effort sleep/Quit, with bounded reads, private files, atomic replacement and safe instance locking. Isolated diagnostics cannot fall back to the default profile history. Disclose activity timestamps and backup scope; request Time Machine exclusion.
- Keep all resource, native macOS14/15, signed distribution and broader parity gates open. No memory-saving claim.

## Foundations between 0.24.1 and 0.25.0 (unreleased)

- Add an isolated same-process native-popover cycle harness with verified presentation/cutoff timestamps, bounded local-only profiles, sampling/interruption guards and build linkage.

- Add an isolated, unlinked fan-policy core for bounded per-fan manual minima/temperature curves, freshness/thermal gating, heartbeat expiry and cooling hysteresis. Document native activation/recovery gates. No SMC writer or fan-control feature is enabled.

- Add an isolated, unlinked modern-traffic client with signature-pinned/root-peer checks, shared-tick request cadence, bounded replies, deadlines/backoff and immediate opt-out invalidation. Move wire/signing types into a narrow IPC target and reject duplicate owner rows. Signed-root acceptance and app registration/integration remain open.

- Isolate shared traffic protocol/accounting and its POSIX boundary from hardware/calendar/probe collectors. Audit each service slice against a minimal direct-framework allowlist. Preserve the app's kernel-only scope and public model names.
- Route the explicit modern scope through a dedicated fixed-provider-9 native entry point; keep providers 9/10 rejected by the kernel entry point. Decode kernel request-echo error frames without retaining their opaque payload. Native request-byte, unprivileged-denial and owned-loopback checks cover these boundaries.

- Add an unbundled, independently implemented modern-connection traffic-service foundation: explicit provider scope, caller-UID filtering, bounded XPC contract, signed-peer/root admission and an expiring read-only session. The preview still uses kernel TCP/UDP only. See docs/PRIVILEGED-TRAFFIC.md.

## 0.24.1 — 2026-10-24 (preview)

- Use the startup mount consistently for storage menu bar/accessibility, Overview and history. Put startup first in the Disks summary; keep missing startup capacity unavailable and every local volume in All readings.
- Detach History content on close so a retained native window does not keep its chart/controls. Add a retained-window regression and preserve the existing discard/recreate lifecycle. No measured memory-saving claim; original resource and full-parity gates remain open.

## 0.24.0 — 2026-10-24 (preview)

- Add a native session History window for CPU, GPU, memory, network, disk I/O and battery, with ten ranges from 10 minutes to 28 days. Share six bounded retention rings and the existing collector/timer; add no routine history disk writes or network requests.
- Draw bars on a fixed, dated time axis, shade uncollected time and disclose peak resolution, actual span, gaps and missing observations. Preserve paired CPU components in numeric exports and retain history across small backward clock corrections.
- Export frozen numeric CSV snapshots through the native Save panel, with explicit units, UTC bounds and validity counts. Keep errors visible, stop projections on close/minimization and keep existing recent menu-bar/dashboard histories unchanged. Session history clears on quit; persistent history and broader parity/resource/distribution gates remain open.

## 0.23.0 — 2026-10-24 (preview)

- Choose System default or any first weekday in Calendar settings, with the same native month preview used by Date & Time. Keep pinned dates, locale/time-zone behavior and event permissions independent of layout.
- Open Calendar settings directly from Time or General. Apply changes immediately, preserve child settings through unrelated edits, collapse the empty calendar list and keep expansion on screen when it fits. Clarify in-app setup and permission states.
- Close isolated resource popovers on shared sample ticks, validate finite measurement intervals and build only the app product during packaging. Keep memory budgets and broader parity gates open.

## 0.22.1 — 2026-10-24 (preview)

- Add a diagnostic launch and benchmark mode that opens the actual status-item popover. Wait for a usable menu-bar anchor without another timer; record presentation explicitly and reject missing visibility, other Settings windows and any close/reopen during measurement. Enable detail collectors only when presentation succeeds. Keep an already shown popover on app reactivation.
- Retain memory attribution and negative rendering experiments without claiming a saving or reducing functionality. Keep the current SDK, native material, charts, history and accessibility.

## 0.22.0 — 2026-10-24 (preview)

- Draw all summary history charts with bars alone, including CPU/GPU/memory/disk/battery. Show up to the existing 300 real samples, using thinner pixel-aligned bars and labeled peak columns when display resolution requires grouping.
- Distinguish missing readings and long unsampled gaps from idle traffic. Keep positive subpixel readings visible with a disclosed one-pixel minimum. Show elapsed span, sample count and recorded cadence; recover the newest valid timeline after timestamp resets.
- Batch bars by color in the existing native view; retain the shared sampler, bounded buffer and separate compact tile trends.

## 0.21.1 — 2026-10-23 (preview)

- Keep Overview and Network summary traffic history as mirrored bars alone; remove their connecting lines and shaded areas. Retain disk and other metric graphics.
- Replace the menu-bar Weather abbreviation with the current forecast condition (Sunny, Cloudy, Rainy, etc.) beside the temperature. Show explicit off, location-needed, updating or unavailable labels when no usable forecast exists; use the same text in the live preview and tooltip.

## 0.21.0 — 2026-10-23 (preview)

- Replace text-heavy Overview, memory, GPU hardware, storage and battery sections with colored metric tiles, capacity rings/meters and bounded mini history charts. Show sensor temperature groups as a compact graphical grid.
- Add full-width CPU/memory process bars and separate pink/blue process I/O bars, with explicit comparison scales. Enlarge network/disk headline rates and add history grid lines.
- Preserve real timestamps and unavailable gaps in mini charts. Keep overlapping RAM categories independent, model power distinct from physical rails, and actual fan RPM unscaled. Reuse the existing native drawing view and shared sampler without extra timers, layers or image caches.

## 0.20.0 — 2026-10-23 (preview)

- Move Weather enablement and explicit location permission to the main Weather tab. Remove General's Weather setup entry; keep custom locations/privacy accessible on the Weather tab without changing enablement. Hide the empty forecast chart during setup.
- Make Overview summary-only, including when another page was showing All readings.
- Reserve stable per-font network rate widths in stacked, history/value and inline styles. Keep both direction slots stable through digit/unit changes and unavailable samples; bound extreme rates and preserve invalid readings as unavailable.

## 0.19.0 — 2026-10-23 (preview)

- Show compact summaries on eight monitoring pages, with complete lists behind All readings. CPU combines User/System history, labeled E/P core rings, five processes, GPU engines, load and uptime in one view.
- Pair disk/network directions in shared-scale bar charts, show memory/capacity quantities and gauges, and group physical temperature, frequency, power and actual fan RPM. Keep missing data, unknown devices and partial network coverage explicit.
- Reuse one native drawing view and bounded accessibility elements. Use real history timestamps, consistent GPU identities and distinct model/rail power sources; add no timer or image cache.
- Derive CPU User/System from the existing tick sample, retain small process percentages and skip general process scans on pages without process lists.
- Show the current-location permission/wait status consistently in Weather's heading, empty chart and provider row.

## 0.18.0 — 2026-10-23 (preview)

- Add numeric meters to Overview CPU/GPU/memory, memory categories and disk capacity, scaled against known total capacity.
- Draw CPU logical-core utilization as compact horizontal meters, retaining efficiency/performance grouping, actual core identities and missing readings. Give GPU device, renderer and tiler readings matching meters; individual GPU-core telemetry remains unavailable when the driver does not expose it. Reuse cells and draw immediately without layers, animations or extra timers.
- Add scaled process CPU/memory meters, battery/accessory charge and health meters, and forecast humidity meters; retain exact numbers and unavailable states.
- Enable Weather on new installs using one-shot Mac Location Services after TinyStats' own permission. Preserve existing settings; scrub stored current fixes before launch, opt-out/re-enable, pause and sleep. Saved Weather cities are selectable through a bounded read-only local cache, with manual coordinates as fallback.
- Keep coordinate/time-zone and city-label editing literal through the existing native field-editor policy, avoiding unnecessary text services.
- Release each completed/cancelled forecast URLSession and its delegate instead of retaining it between refreshes. Add a failing-before/passing-after lifetime regression. Shared sampling and provider rate limits are unchanged.

## 0.17.0 — 2026-10-22 (preview)

- Customize the Date & Time world-clock table with text tokens and eight presets, including seconds and offsets relative to this Mac. Preview the actual selected cities with the same renderer, fonts, alignment and column widths as the detail table, then save the shared format atomically.
- Share seconds demand across menu-bar and world-clock editors. Detail-table seconds use the existing visual clock without adding hardware samples; closing previews removes their demand.
- Preserve legacy formats and reject malformed or oversized drafts. Drop city labels containing Unicode line separators while retaining their zones.

## 0.16.1 — 2026-10-22 (preview)

- Keep world-clock identifiers, clock names and format tokens literal by disabling automatic spelling/grammar checks, correction, substitutions, completion and Writing Tools in their native window field editor. Reuse AppKit’s editor; other windows and global text preferences are unchanged.
- Add standard Edit → Undo/Redo keyboard commands for native text input.
- Cover editor reuse, local policy, Unicode/tokens, native text Undo/Redo and window/controller release. This avoids unnecessary text services; the broader Settings memory gap remains open.

## 0.16.0 — 2026-10-22 (preview)

- Mix native analogue dials, second hands and mini calendars with text in custom menu bar clocks. Add fuzzy English time and zone offsets relative to the Mac, with presets and the same production-renderer preview.
- Draw bounded vector atoms directly in existing status views, with spoken time/day descriptions and no image cache, layer, animation loop or additional timer. Seconds still follow the shared visual clock without increasing hardware collection.
- Cover dial angles, fuzzy rounding, date-line/historical offsets, DST, bounded mixed content, Light/Dark drawing and editor seconds demand.

## 0.15.1 — 2026-10-22 (preview)

- Create native clock date formatters only for tokens that need them. Numeric/literal clocks use no DateFormatter; localized date words share one, and localized system times add their formatter on demand. Preserve the bounded zone cache and all display behavior.
- Add a before/after allocation regression covering numeric output, localized words, formatter reuse, system-time formats and invalidation. This reduces unnecessary formatter objects; the broader memory-budget gap remains open.

## 0.15.0 — 2026-10-22 (preview)

- Configure up to six menu bar clocks with names, time zones, one/two lines, literals, Unicode and named date/time tokens. Add presets, ordering, atomic Save/Revert and a native production-renderer preview under Menu Bar → Time formats. Preserve legacy clock settings by default.
- Advance seconds and minute boundaries on the existing shared timer without adding hardware samples, history points or alert evaluations. Bound formatter caches and remove editor demand on close; static clock styles avoid time formatting.
- Keep Today and the calendar selection synchronized across midnight between hardware samples while preserving explicitly selected days and original sample timestamps.

## 0.14.1 — 2026-10-22 (preview)

- Release Settings page contents on window close even when AppKit retains the native tab view. Preserve drafts while switching tabs; reopening creates a fresh controller from saved settings.
- Add a rendered native lifetime regression covering retained tab views, both pages, the preview and battery editor. Resource-budget validation remains required.

## 0.14.0 — 2026-10-22 (preview)

- Choose battery percentage, remaining time, percentage plus time, signed battery watts or power status. Configure separate styles/values for draining, charging, OS-confirmed charged and external-power/charge-held states.
- Add a Battery formats editor under Menu Bar with the actual production renderer, native appearance and clearly labeled preview-only state examples. Per-state styles override the base style only when enabled; value-format controls follow text-style availability.
- Require the final Swift Testing completion summary in CI; replace animated offscreen unit-test button clicks with native target/action delivery to avoid exposing an early-success async-main runtime exit.
- Read the OS charge-completion flag on the existing battery cadence; do not infer full charge from percentage or external power alone. Keep unknown estimates unavailable and graph/gauge quantities tied to battery percentage. Add no collector, timer, helper, permission or network request.

## 0.13.0 — 2026-10-22 (preview)

- Name up to six world clocks in General settings using `Name=Zone`, alongside existing zone-only entries. Preserve legacy settings and independently recover damaged labels without losing valid clocks.
- Save valid clock edits as one batch; reject invalid zones, duplicates and oversized labels without replacing saved clocks. Keep unsaved drafts across Settings tabs. Labels and time-zone rules remain separate, including daylight-saving transitions.
- Reuse the existing Date & Time formatter and shared sampler. Add no timer, collector, account permission or network request. Richer clock formats remain unfinished.

## 0.12.0 — 2026-10-22 (preview)

- Show native Wi-Fi radio state, signal/noise/SNR, channel/band/width, PHY, security type and transmit link rate in Network details. Keep link Mbps separate from traffic bytes per second; zero/error and unknown fields remain unavailable.
- Read current radio telemetry only while Network details are selected, at most once every five seconds on one bounded utility job. Reject stale/interface-replacement results, expire cached readings and release the client when details close or pause/sleep resets collection. No scan, association, radio setting change, network identity lookup or Location permission request.
- Add regression coverage for unavailable fields, slow jobs, cache expiry, failures, interface churn, stop/restart and native table rendering. Add explicit local `--diagnose --wifi` diagnostics.

## 0.11.2 — 2026-10-22 (preview)

- Build each Settings tab on first visit instead of constructing both immediately. Retain visited tabs and unsaved clock drafts until the window closes; edits preserve choices on the unbuilt page.
- Skip hidden Menu Bar preview updates and apply the latest readings, appearance, order and pause state on return. Direct Menu Bar preview launch no longer constructs General first. Collection still uses the existing shared sampler.
- Add regression coverage for both initial pages, untouched settings, drafts and hidden-preview catch-up, plus a reproducible manual General settings benchmark workload.

## 0.11.1 — 2026-10-22 (preview)

- Count sleep in weather cache age, refresh intervals and provider backoff using a sleep-inclusive monotonic clock. Project timestamps into the sampler’s awake-time reference for UI and queued-alert checks, so an overnight cache stays unavailable until confirmed or replaced.
- Bound displayed age/backoff labels without shortening provider deadlines; very large waits display “>1 year” instead of overflowing an integer conversion.

## 0.11.0 — 2026-10-22 (preview)

- Add opt-in MET Norway weather for a manually chosen location, with provider/coordinate/IP disclosure before Apply, immediate opt-out and no automatic location lookup. Keep forecasts in bounded memory, respect cache headers and rate limits, and cancel/reject stale requests on lifecycle changes.
- Add Weather details with modeled current conditions, a 48-hour forecast chart, daily sampled low/high, upcoming timestamps and explicit precipitation periods. Show temperature or a native condition icon in the menu bar using the existing style/font/color renderer. Stale forecasts withhold current values; unavailable conditions use a question-mark icon.
- Add fresh forecast temperature, wind and next-hour precipitation rules, with current opt-in/revision/freshness checks before queued notification delivery. Notifications remain separately opt-in.
- Keep weather scheduling on the existing shared sampler, with no default weather reader/session, per-view timer, subprocess or background process scan. Add bounded transport/decoder/lifecycle/privacy fixtures and an explicitly enabled public-example benchmark.

## 0.10.0 — 2026-10-22 (preview)

- Choose System, Light or Dark for TinyStats windows and panels. Move menu bar controls into a dedicated Menu Bar tab with a live, actual-size preview using the production renderers, native menu bar appearance, individual-item padding/order and pause indicators. Style/color changes update existing status items without recreating them.
- Label each logical CPU reading using explicit efficiency/performance topology where available; unknown layouts keep neutral labels. Automatic per-core menu bar colors distinguish efficiency and performance, while explicit user colors still apply to every bar.
- Group sensors by CPU, GPU, fans, memory, storage, battery, Neural Engine and system, with unidentified readings retained under Unclassified. Show component sensors on matching detail pages and group the menu sensor chooser.
- Show driver-reported GPU shader core counts and renderer/tiler utilization separately from device utilization. Individual GPU-core activity remains unavailable; device-wide values are never copied into fake per-core readings. Cache static GPU metadata at discovery cadence.
- Run tests and Release diagnostics natively on macOS 15 Apple Silicon and Intel, with architecture/OS assertions and retained compatibility logs. Add an on-demand macOS 14 check using Xcode 16.2 while the hosted image remains available; physical hardware and lifecycle validation remain separate release gates.

## 0.9.0 — 2026-10-22 (preview)

- Separately opt into Apple HTTPS response checks and ipify IPv4/IPv6 discovery in Settings → Internet checks. Destinations, cadence and public-IP disclosure appear before enablement. Nothing is enabled by default.
- Show response state, full HTTPS check time, provider-reported addresses and result ages in Network details. These follow the OS route/proxy/VPN and do not measure ICMP ping or prove general internet reachability.
- Add rules for HTTPS response state/time and observed public-IP changes. First baselines never trigger changes; new observations rearm independently, and queued delivery rechecks current opt-ins and revision.
- Reuse the shared sampler for scheduling and timeouts, with one logical request, bounded bodies, no cookies/stored credentials/redirects, cancellation on pause/sleep/opt-out and stale-result rejection.

## 0.8.0 — 2026-10-22 (preview)

- Opt into an account-event agenda in Settings → Calendar events, request macOS Calendar access explicitly, and choose all calendars or a subset. TinyStats never writes events or uploads/persists event content.
- Select dates with native day buttons, navigate months with leap-day clamping, and retain a pinned civil day across time-zone changes. Show all-day and timed events, including day-spanning indicators.
- Keep EventKit on one utility queue with bounded results, one in-flight operation, coalesced change invalidation and the existing sampler cadence. Clear stale/hidden/paused agenda results and skip unused process scans on Date & Time.
- Preserve calendar choices across unrelated parent-settings edits, and fail closed when a stored calendar selection is malformed. Live authorized-account and permission-transition validation remain open.

## 0.7.0 — 2026-10-22 (preview)

- Open Network details for the top eight process owners exposed by native kernel TCP/UDP accounting. Socket bytes cover all interfaces, including loopback, separately from the selected-interface link counters. See the [network guide](docs/NETWORK.md) for scope and warm-up behavior.
- Retain verified final counters for short-lived sockets, identify owners by PID plus kernel unique ID, and keep failed, missing, overflowing or reset intervals unavailable until fresh baselines are established.
- Collect only while Network details are selected; stop on hide, module switch, pause or sleep. Reuse the shared sampler and one read source, with bounded socket/owner state and buffers, without another timer, subprocess or external request.
- Clear raw bytes immediately after decoding and never decode, log or retain endpoint fields. Add deterministic protocol/accounting/lifecycle regressions and an opt-in owned-loopback fixture for baseline exclusion, active TCP, short-lived TCP and closed UDP.
- Keep modern connection/QUIC coverage and full application aggregation explicitly incomplete; this milestone does not claim full per-app network parity.

## 0.6.0 — 2026-10-22 (preview)

- Reproduce the supplied stacked temperature/network/disk/CPU/memory arrangement, or choose among 13 native menu bar style families where meaningful. See the [menu bar guide](docs/MENU-BAR.md) for setup and per-metric availability.
- Choose Compact/Standard/Large fonts for text styles and seven semantic colors per readout; scroll wide settings previews horizontally and retain combined or macOS individual-item ordering.
- Keep History + value updating with details closed, preserve missing-versus-zero rendering, and show charging as a separate battery badge.
- Reuse bounded font/symbol caches and existing sampled history without another timer; preserve earlier settings with defaults and isolated appearance decoding.
- Add deterministic Light/Dark rendering fixtures for styles, sizes, long values, missing/zero data and charging. Richer clock/battery formatting and complete commercial preset/metric parity remain unfinished.

## 0.5.0 — 2026-10-22 (preview)

- Show local IPv4/IPv6 addresses and prefixes, IPv6 scopes/address state, point-to-point peers, primary routes, configured routers/DNS, service names/types, MTU and interface flags.
- Auto traffic selection prefers the available IPv4 primary interface, then IPv6, while counting one interface to avoid tunnel/physical double counting. Local route availability is explicitly separate from internet reachability.
- Remove address enumeration from every traffic sample. Dynamic-store notifications only invalidate a bounded cache on the existing worker queue; discovery coalesces into the next tick, with interface-identity/flag invalidation and a 30-second fallback.
- Clear failed discovery instead of retaining stale addresses; keep successful empty results distinct. Interface replacement also restarts pending local-rule holds.
- Add protocol, cache/failure/recovery, scoped-address, IPv6 fallback and replacement regressions. A Copy value context action retains full detail values, including long IPv6 addresses.

## 0.4.0 — 2026-10-22 (preview)

- Show residency-weighted active frequencies for supported Apple Silicon CPU clusters and GPU, using hardware frequency tables and the existing slow sampler cadence.
- Expose supported CPU/GPU/Neural Engine/DRAM energy-model estimates as typed power sensors, selectable in the menu bar and local rules. A channel must actually advance before reporting zero watts.
- Load the optional IOReport interface dynamically, subscribe only to bounded relevant channels, and reset subscriptions/baselines across pause and sleep. Unknown interfaces, units and state tables stay unavailable.
- Add deterministic table/unit, idle/reset, energy-placeholder and settings/rule regressions, plus extended local hardware diagnostics with --diagnose --hardware.

## 0.3.0 — 2026-10-22 (preview)

- Configure up to 32 local alert rules by metric/source, threshold, sustained duration, cooldown, once/repeat behavior and optional sound in a native Save/Cancel editor.
- CPU/GPU, memory, volume/I/O, interface traffic/link, typed sensors, battery/power, thermal and SMART conditions reuse the shared sampler without new timers or probes.
- Preserve legacy defaults and valid rules during migration; keep missing data distinct from recovery, expire cached observations, and reset holds for replaced devices.
- Persist GPU model groups and hashed SMART device selectors; recheck current notification opt-in and exact rule before delivering queued events.
- Expand deterministic rule regressions and add an isolated 32-rule Release benchmark workload.

## 0.2.0 — 2026-10-22 (preview)

- Read-only NVMe health with critical flags, temperature, spare/endurance estimates and lifetime counters; ATA threshold status where exposed.
- Bounded asynchronous SMART collection: on demand in disk details, with optional five-minute background polling and fresh-observation alerts.
- Choose a discovered sensor for the menu bar. Discovery preserves power, voltage, current and fans alongside temperatures within the same 128-sensor cap.
- Signed sensor history with a zero baseline, stable Fahrenheit history during missing readings, and explicit unavailable/unreported SMART fields.
- Regression coverage for NVMe byte order/overflow, stale alerts, slow-device isolation, sensor migration/selection and graph domains.

## 0.1.0 — 2026-10-22 (preview)

- Native CPU/GPU/memory/disk/network/sensor/battery/time monitoring with in-memory history and on-demand top process lists.
- Per-metric text, stacked, history, bar, pie and CPU per-core menu bar styles. Combined/individual layouts, ordering and live preview.
- Power-aware shared sampling, sleep/pause baseline recovery, validated preferences, world clocks, local calendar, login and opt-in local alerts.
- Reproducible universal macOS 14 app packaging, tests, real-app benchmark harness and local CI scripts.

The preview is not notarized. Hardware support and advanced feature gaps are documented in docs/ROADMAP.md.
