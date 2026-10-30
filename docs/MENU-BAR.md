# Menu bar styles

Select **Menu Bar** in the bottom **Settings** sidebar group to enable readouts and choose each one's **Style** and **Font**. Labels, numbers and graphical fills adapt to the native menu bar appearance. The main content moves into a persistent resizable window, which survives focus loss and monitoring-tab changes. Its minimum content size is 884×660; switching tabs preserves the chosen window size. Settings forms stay at most 740 points wide and the preview retains actual menu-bar sizing. Changes apply immediately. Click a status item for detail pages; changing its style does not create a separate collector.

**Picture presets** below the live preview apply **Simple text** (Standard), **Compact bars** (Compact), or **Separate** (Standard stacked label + value) to every enabled readout, preserving the readout list and order. Compact bars uses supported gauges and falls back to text for rates, non-temperature sensors, Time and Weather. Every readout remains a separate native menu bar item. The inset Readouts group starts expanded, with module icons/names, native Style/Font choices and switches. The sensor selector has its own group; Battery/Clock formats remain available below it. **Hide readout & style options** collapses these controls; **Customize readouts & styles…** reveals them again. Manual changes clear the preset highlight unless every enabled readout matches its style and size.

## Switching an open view

Status-item dropdowns use a 344×640-point popover material with neutral Control Center platters, large label-colour values and accent graphics. Module content scrolls when needed. History…, Open [module] in TinyStats, All readings / Summary (Calendar… for Time), and Pause / Resume are full-width menu-style rows at the foot, where applicable. The open action promotes the same controller to the persistent window and preserves the selected module; it does not visit Settings. CPU cores use vertical capsules in verified E/P secondary/primary accents. History plots disclose their observed duration, sample count and numerical scale, including empty/unavailable states; valid zero readings remain data. Battery detail tiles use two columns in the narrow dropdown. Memory composition uses a segmented accent bar. Sensor search, calendar date selection and explicit Weather controls remain native controls.

Selecting a different readout switches the existing popover directly to that page; selecting its current readout closes it. Outside clicks, Escape and app switching dismiss the popover. Text editors and attached sheets handle Escape first; in Sensors search, Escape clears the search while keeping the popover open. Settings opens in the persistent resizable window, which stays open after focus loss. Readouts then select pages in that same window. Dismissal handlers are active only while the popover is open. See the 0.35.5 evidence and physical-input limits.

## Reproduce the supplied stacked layout

1. Enable **Sensors**, **Network**, **Disks**, **CPU** and **Memory**. Disable other readouts for the same five-item arrangement.
2. Set **Menu bar sensor** to **CPU · hottest recognized sensor**. Leave **Use Fahrenheit** off for the Celsius version of the example.
3. Choose **Stacked label + value** for all five readouts. Use **Standard** font; colors are automatic.
4. Hold **⌘** and drag the native menu bar items into **Sensors → Network → Disks → CPU → Memory** order. The preview follows observed native positions; scroll it horizontally when needed.

The sensor displays a CPU label over temperature, Network puts upload above download, and the remaining items put SSD/CPU/MEM labels over percentages. Values come from the current readings; matching the arrangement does not imply matching a reference image's sample numbers. Unsupported readings remain unavailable.

## Fourteen style families

“All readouts” below means CPU, GPU, Memory, Disks, Network, Sensors, Power (battery formats) and Time. Percentage/temperature gauges apply to CPU/GPU usage, memory, disk capacity, battery level and temperature sensors. Fans, power, voltage and current have no percentage gauge; Network rates and Time also exclude gauges.

| Style | Availability and behavior |
| --- | --- |
| Label + value | All readouts; one line with the metric label and value |
| Stacked label + value | All readouts; label above value, or upload above download for Network |
| Value only | All readouts; omits the metric label, retaining both Network directions |
| Label only | All readouts; a static metric label, or the local weekday for Time |
| Icon only | All readouts; the module's symbol, with readings still available in details |
| History graph | All except Time; last 40 samples, with two Network series |
| History + value | All except Time; the same graph beside a stacked current readout |
| Vertical gauge | Percentage/temperature readings |
| Labeled vertical gauge | Three vertically stacked label letters beside a colored upright gauge; CPU/GPU/MEM/SSD and other percentage/temperature readings |
| Labeled horizontal gauge | Percentage/temperature readings; fixed small caption above a horizontal bar |
| Pie gauge | Percentage/temperature readings |
| Ring gauge | Percentage/temperature readings |
| Per-core bars | CPU only; the first 32 logical cores, where exposed |
| Battery icon | Power/battery readout only; level body with a separate charging badge, or a plug on a Mac without an internal battery |

Temperature gauges use a fixed 0–120°C scale. Fahrenheit changes temperature text while retaining that thermal scale. Sensor histories retain their measured units; signed current graphs include a zero baseline. Network uses decimal B/KB/MB/GB per second in the menu bar, while details use binary KiB/MiB/GiB per second.

## Font, color and ordering

**Compact**, **Standard** and **Large** apply to Label + value, Stacked label + value, Value only, Label only and History + value. General value fonts are 10/11/13 points. Stacked Network values use 10/10.5/11 points to keep both lines within native menu bar height; small stacked labels and horizontal-gauge captions remain fixed. Other styles disable the Font control rather than suggesting it resizes a graph, icon or gauge.

Menu bar text is near-black without a shadow on light bars and white with the existing subtle dark shadow on dark bars, including stacked labels, rates, missing-value dashes and vertical gauge letters. All graphical families (including symbols, clock dials/calendars, gauges, history and battery graphics) follow `NSColor.controlAccentColor`, resolved in the native status item's appearance. Graphics first apply the shared contrast correction from [Design](DESIGN.md#derived-secondary-accent-2026-10-30). Dark-bar primary graphics retain their existing 18% white lift. Paired Network history uses primary for download and the opaque derived secondary for upload; verified E/P cores use secondary/primary. Gauge outlines retain label colour at 65% opacity. Verified efficiency cores use the opaque derived companion, performance cores use primary, and unclassified cores use a neutral label tint. Legacy stored tint fields still decode but do not override rendering. GPU has no verified E/P topology or individual shader-core utilization adapter.

The preview sits on an appearance-aware neutral wallpaper-like strip. It does not read the desktop image or request access. It uses the same renderer, current readings, native menu bar appearance/height and per-item padding as the actual status items, including pause markers. Each item has 1-point side padding; entries within a shared clock item use a 3-point gap. Network direction arrows stay at the leading edge while numeric fields stay fixed-width and right-aligned, including short rates and missing values. macOS controls spacing outside each native item. Font changes update the existing items. Physical menu bar space and wallpaper/translucency remain outside the preview.

**Settings → General → Appearance** chooses System, Light or Dark for TinyStats windows, detail panels and child settings. It does not change macOS appearance. Menu bar colors follow the status item’s effective appearance independently of the window theme and redraw when that appearance changes or the system colours change. No background plate or Backing setting is added. Palette tests check accent resolution, label contrast, companion derivation, dark-bar shadow and stable widths; a full dark-bar PNG byte-identity baseline is not part of this change. TinyStats does not sample wallpaper or screen pixels, request new permissions or make network requests for contrast. One appearance covers the item, so local patches of busy wallpapers can still reduce contrast. The Menu Bar preview follows the actual native menu bar appearance independently from the window theme. No animation or extra timer is added.

Every readout is a separate native status item, including migration from saved combined layouts. Its sender identifies the destination page directly; routing no longer depends on forwarded click coordinates. Multiple custom clock entries share the Time item. Native **⌘-drag** and saved macOS positions control ordering. The settings preview follows observed positions and scrolls horizontally when needed. The old combined-layout selector and ordering arrows are removed. Available physical space still limits which items macOS can show. Independent physical status-item click delivery remains a validation gap; the routing change is not proof of the original forwarding cause.

## Battery values and power-state presets

Use **Battery formats…** below the readout group to open **Battery Menu Bar Format**. The default value format follows the main row's style. **Use different displays for each power state** enables four independent value/style presets: On battery, Charging, Charged and On AC · not charging. The main Power style is disabled while presets are enabled; font size remains shared and colors are automatic. Text values apply to Label + value, Stacked, Value only and History + value. Other styles disable the value-format control and keep battery-percentage semantics, including horizontal gauge captions.

The editor reuses the production renderer at native height and menu bar appearance. Choose **Live reading** or a clearly labeled **Example** to inspect a different state. Examples change only that preview; they never enable the Battery item, replace collected readings, add fake history or write state into settings. The main Menu Bar preview always uses live data. See [battery formats](BATTERY.md) for estimates, charge-hold handling and limits.

## Data, persistence and resource limits

Settings builds each tab on first visit and retains visited pages until the window closes. Switching tabs preserves unsaved world-clock text. The hidden or minimized Menu Bar host skips preview updates, including clock/context changes, and catches up with current readings and native bar appearance when shown again, using the same shared sampler. Closing detaches the embedded page tree.

Missing readings display as an em dash or an unavailable graph/gauge state. Missing history samples break a line; a valid zero remains zero, including an empty zero-level gauge. Icon/label-only styles deliberately omit the number. Battery AC is the no-internal-battery state rather than a fabricated charge percentage.

Both graph families use the last 40 points from the existing bounded history. When a visible readout uses History graph or History + value, history is delivered even with details closed. Graphs add no timer or sampling request. Rendering reuses bounded shared font/symbol caches and draws directly into native status buttons, without an animation loop.

Existing raw style choices remain, while legacy combined layouts migrate to individual native items. Missing appearance settings default to Standard/Automatic; malformed appearance entries fall back per module without erasing unrelated choices. Unsupported persisted style/metric combinations use the stacked fallback. Changing sensor quantity limits its styles to meaningful options rather than inventing a fan/power percentage.

## Research and remaining scope

[Bjango's official feature overview](https://bjango.com/mac/istatmenus/) is the competitive feature reference. A separate read-only UI inventory of **iStat Menus 7.30** observed vertical, pie, ring and labeled-horizontal gauges, along with value, stacked, icon, label, history and per-core presentations. These are visible UI observations, not claims about its implementation. TinyStats' renderer is independent; no proprietary code or assets were copied.

This milestone supplies these native style families for TinyStats' existing readings. It does not reproduce every commercial preset or metric combination. Custom one/two-line clocks, inline analogue dials, mini calendars, fuzzy time and Mac-relative offsets are documented in [clock formats](CLOCKS.md). Deterministic [rendering fixtures](../Tests/TinyStatsUITests/MenuBarRenderingTests.swift) generate a local gallery with the production renderer.

Weather offers the five text/icon families and uses its opt-in forecast temperature or condition symbol. It has no percentage gauge or fast-sampler history. Configure the provider/location on the Weather monitoring tab; see [Weather](WEATHER.md).
