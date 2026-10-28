# Battery menu bar formats

Open **Settings → Menu Bar** and use **…** beside Power. Enable the Power readout in the main tab if you want it in the menu bar; opening its format editor does not enable it. Settings apply immediately and the editor uses the same renderer, fonts, colors and native menu bar appearance/height as the actual item.

## Values

| Format | Meaning |
| --- | --- |
| Percentage | Internal battery level, preserving the existing default |
| Time remaining | `h:mm` until empty while draining, or until full while charging; the stacked caption distinguishes LEFT and TO FULL |
| Percentage + time | Percentage above a directional time (`↓` until empty, `↑` until full); single-line styles retain both values |
| Battery watts · signed | Signed OS battery current × voltage in watts, not whole-Mac/adapter/wall power; positive and negative signs are retained |
| Power status | Battery, Charging, Full or On AC |

Unknown, nonpositive and out-of-range time estimates remain `—`; no estimate is synthesized from level or past drain. The display accepts up to seven days of reported minutes, keeping conversion and width bounded. A charged battery displays Full; an external-power battery that is not charging displays AC instead of using an irrelevant time-to-empty value. Invalid/nonfinite percentage and watts stay unavailable. The signed-watt display rejects magnitude above 10,000 W as invalid input.

Value formats apply to Label + value, Stacked label + value, Value only and History + value. Icon, label-only, plain-history and gauge styles disable the corresponding value-format control. Graphs and gauges always represent battery percentage, even beside watts or time. Colors and fonts follow the main Power row. The internal `battery` preference/history key remains unchanged; renaming the displayed module does not migrate or replace saved choices. A plug is drawn for absent internal readings; it is distinct from a real battery plugged into AC with charging held. The existing no-internal-reading AC fallback is not a new proof of power-source availability after an underlying API failure.

## Separate power states

Enable **Use different displays for each power state** to choose a value and style for each state. Otherwise the main Power style and default value format continue to apply, preserving old preferences.

| State | Source and precedence |
| --- | --- |
| On battery | The internal reading is not on external power |
| Charging | External power and the OS charging flag |
| Charged | External power, not charging, and the OS `kIOPSIsChargedKey` is explicitly true |
| On AC · not charging | External power without charging or explicit charge completion; includes charging held/paused and an unavailable completion flag |

The OS completion flag is authoritative: percentage alone is not a completion test. Apple's SDK documents that a plugged-in battery can validly be below 100% and not charging. A 100% reading with no completion flag stays in the external-power state. Conflicting charge flags cannot override the on-battery/charging precedence above.

Enabled presets override the main row's Power style, so that control is disabled while presets are on. The four state rows retain their choices when disabled. Unsupported saved state styles fall back to Stacked, and malformed fields recover independently without erasing other presets or unrelated settings. No internal reading uses the default format/style rather than guessing a state. History is delivered from the existing bounded ring when an enabled Power item could use a base or state history style; it adds no collection work or separate history store.

## Preview and resource behavior

**Live reading** uses the current sampler snapshot. The explicit **Example · …** entries demonstrate each power state on a desktop as well as a laptop. They affect only this editor's preview: no fake telemetry enters the collector, detail pages, alerts, saved settings or main Menu Bar preview. Example history remains empty. A context line says whether Battery is enabled. Examples are not physical laptop or battery-transition validation.

The editor is created only on demand. It uses existing shared sampler deliveries, skips redraws while hidden, follows parent appearance changes and closes with Settings. Preview source and example state are not persisted. Battery charge completion is one dictionary field read in the existing native battery collection; no new timer, subprocess, helper, permission, network call or polling cadence is added.

Independent implementation references: [Bjango power-state customization](https://bjango.com/help/istatmenus7/power/) for feature scope; Apple's installed `IOKit/ps/IOPSKeys.h` for the public power-source field semantics. No proprietary implementation or assets are copied. Native laptop/runtime and actual charge/hold/AC transition evidence remain open; see validation and [performance](PERFORMANCE.md).

## Power monitoring page (0.29.0)

Power consolidates internal battery/accessories, energy mode and recognized power sensors. All readings retains raw power, voltage and current values; model/rail scopes can overlap and are not summed into whole-Mac or wall power. Missing CPU power remains unavailable. CPU/GPU cooling views route explicitly owned fans and label ambiguous generic fans shared/unassigned; no fan write is enabled. Synthetic populated laptop fixtures establish renderer geometry only, not physical charge/hold/AC transitions. See review and native scope.
