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

## Show Power per power source (0.37.3)

**Settings → Menu Bar → Power** has a small **Show in menu bar** group (eye glyph) above the style tiles with two picture toggles: **On Power Adapter** and **On Battery**. Each has a Power-green plug or battery glyph and a tiny menu bar showing the chosen Power style (on a Mac without a battery the adapter tile shows the same **BAT AC** readout as the live preview) or an empty dashed slot; an accent eye / secondary-colour filled eye-slash mark shows the choice. The tiles use a neutral card (no accent selection border), span whole style-grid columns and sit 16pt+ apart from the styles, so they read as two independent switches rather than a style choice. Both are on by default, so existing profiles behave exactly as before. The choice is saved as `batteryMenu.visibility` (`onAdapter`, `onBattery`); a missing key means both on, and a malformed field recovers to on without touching the other field or any other Power choice. The internal `battery` readout key is unchanged.

The power source comes from the existing native battery reading (`externalPower`), delivered by the shared sampler. An empty reading keeps the last source a battery reading confirmed this session (a failed read on a laptop does not flip it); a Mac that never reported a battery (desktop) counts as power adapter. Settings likewise keeps **On Battery** available once a battery has been seen. There is no new timer, observer or poll, so a plug/unplug is reflected within one battery sampling period (at most about five seconds plus the update interval).

- **Separate:** only the Power status item is removed and re-created, reusing its autosave slot; nothing hidden is persisted, so the menu bar ordering and other items are untouched. Order adoption pauses while Power is hidden because the native set is incomplete.
- **One:** the shared item drops the Power segment; click routing uses the remaining segments and keyboard/VoiceOver activation uses the first drawn module. Rendering and activation share one list, so when Power was the only readout the TinyStats overview it is replaced by is also what a keyboard press opens.
- An open Power dropdown closes when its item hides.
- Hidden by power source is not "disabled": Power stays in **In menu bar**, keeps its styles, and Settings, main window and History are unaffected. If both tiles are off (or **On Power Adapter** is off on a Mac without a battery) a one-line caption says Power stays enabled. If Power is the only readout and is hidden, the TinyStats item remains so the app is still reachable.
- On a Mac without an internal battery the **On Battery** tile stays visible but dimmed, captioned **No Battery** with no mark and no icon, and ignores clicks. A visible dimmed tile keeps the layout stable, explains why the choice does not apply and preserves the saved value for profiles copied from a laptop; hiding it would leave a lone tile indistinguishable from the module toggle.

## Energy mode profiles (0.37.3)

The Power dropdown has an **Energy mode** card with one row per power source macOS keeps a profile for: **Power Adapter**, and **Battery** only on Macs with a battery. Each row is a native segmented control: one filled glyph family (leaf = Low Power, Ⓐ = Automatic, hare = High Performance) (only where supported), each with a tooltip; the selected segment keeps the system accent (`selectedSegmentBezelColor`) under glass. The row for the current source has a faint neutral highlight, a medium-weight label and full-strength glyph; glyphs and segments align with the card title and trailing text. The card sits directly under the Battery / Power source header and appears only in the dropdown; the main window Power page is unchanged.

### What macOS supports (investigated read-only on macOS 27.2)

| Mac | Modes | Sources |
| --- | --- | --- |
| Apple-silicon MacBook Air / 13" MacBook Pro | Low Power, Automatic | Battery and Power Adapter |
| 16" MacBook Pro with M1 Max or later Max chips; 14" MacBook Pro with M3 Max; MacBook Pro introduced in 2024 or later with a Pro or Max chip | Low Power, Automatic, High Power | Battery and Power Adapter |
| Mac mini / iMac | Low Power, Automatic (High Power on Mac mini M4 Pro) | Power Adapter only |
| Mac Studio (2026) | Low Power, Automatic, High Power | Power Adapter only |
| Earlier Mac Studio | Low Power, Automatic | Power Adapter only |

Apple maintains the authoritative list of Macs with High Power: [Use High Power Mode on your Mac](https://support.apple.com/en-us/101613). Only the Mac mini M4 row was observed here (`pmset -g custom`: one `AC Power:` section with `lowpowermode`; `pmset -g cap` lists `lowpowermode`). The other rows come from Apple's list and release notes and are **unverified** on hardware. TinyStats never consults this table at runtime; it offers modes from `pmset` key evidence only (below). `man pmset` does not document these keys, the public SDK has no energy-mode API, and `ProcessInfo.isLowPowerModeEnabled` only reports the effective state. System Settings' own pane (`com.apple.Battery-Settings.extension`) labels the choices Low Power / Automatic / High Power, with High Power strings only in a per-model table.

### Detection and reading

When the dropdown opens on Power, TinyStats runs `/usr/bin/pmset -g custom` and `/usr/bin/pmset -g cap` once each on the sampler's serial queue (2-second timeout, 64 KiB output cap, fixed environment, no shell). This is a one-shot read per opening, never at launch and never periodic. Sources are the `AC Power:`/`Battery Power:` sections; `UPS Power:` is ignored. Key evidence decides the layout — no model list is consulted, because a wrong list could offer or write an unsupported setting:

| Keys present | Layout | Offered | Write |
| --- | --- | --- | --- |
| `powermode` | unified | Low / Automatic / High | `pmset -c\|-b powermode 1\|0\|2` |
| `highpowermode` | legacy pair | Low / Automatic / High | `pmset -c\|-b lowpowermode X highpowermode Y` |
| `lowpowermode` only | Low Power only | Low / Automatic | `pmset -c\|-b lowpowermode 1\|0` |
| none / no source section | unsupported | card hidden | — |

Unknown or conflicting values (for example `powermode 7`, or both legacy keys set) leave the row without a selection rather than guessing Automatic. If `pmset` cannot be read the card shows only **Settings…** (tooltip: Open Energy Mode in System Settings).

### Changing a mode — privilege decision

Writing a per-source energy setting requires root. Options considered:

1. **Per-change administrator prompt** — `osascript -e 'do shell script "/usr/bin/pmset -c powermode 2" with administrator privileges'`, run off the main thread. The command text is assembled only from a fixed token whitelist (`-b`, `-c`, the three key names, `0`–`2`) and rejected otherwise; no user data is interpolated. No helper, no persistent privilege, the standard macOS prompt every time. Downsides: an administrator prompt on every change, not allowed in a sandboxed App Store build, and the prompt takes focus so the dropdown closes (the result is applied and re-read regardless).
2. **SMAppService privileged daemon** — silent changes after one Login Items approval, but adds a root code surface, signed-peer XPC validation and the install/registration lifecycle described in [Privileged traffic](PRIVILEGED-TRAFFIC.md). Not built or registered here.
3. **Deep link** — `x-apple.systempreferences:com.apple.Battery-Settings.extension` opens System Settings › Battery (Energy on desktops; same extension). No privilege at all, but the person changes the mode there.

**Implemented and recommended for direct distribution: (1), with (3) as the fallback.** macOS stores the per-source value itself, so it switches automatically on plug/unplug with no TinyStats background process. The `EnergyModeApplying` protocol isolates the privileged step; it runs only from an explicit segment click, never at launch, refresh or rendering, and tests inject fakes. While the prompt is open the row is disabled with **Waiting for approval…**. Cancel → **Energy mode unchanged**; failure → **Couldn't change energy mode**; either way the selection reverts to the value re-read from `pmset`. Every change ends with a fresh read that starts after it; reads already in flight are discarded and the row stays disabled until that read lands and **Settings…** (tooltip: Open Energy Mode in System Settings) appears. Messages expire after two minutes without a timer (checked when the card is drawn). An App Store build would ship (3) only; (2) is worth it only if silent switching is requested and the privileged-traffic signed-peer pattern is validated first.

Open items for the maintainer: run one real change on a laptop and on a High Power Mac to confirm the prompt, `pmset` exit codes and that System Settings reflects the change; confirm the macOS 14/15 key layouts; decide whether a hardened-runtime/notarized build needs any entitlement for `osascript` administrator prompts (none is expected because no Apple Events are sent to another app — unverified).
