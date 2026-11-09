# Welcome tour v2: “The menu bar is the hero”

2026-11-10 · branch `feat/welcome-tour-v2` @ `eec1cd0` (v0.37.0/72) · Designer: Claude (huashu-design) · Status: **Direction A approved 2026-11-10** (see `design-mockups/direction-approved.md`); implement this document

This is the implementation spec for the redesigned first-run tour. It replaces the six-step tour described in [Design › Graphic-first welcome tour](DESIGN.md#graphic-first-welcome-tour). The design changes layout, graphics, step count and copy. It **does not** change any feature, preference key, collector, permission or network behaviour.

Mockups: `design-mockups/index.html` (git-excluded). It shows step 1 in all three directions, then every step of direction A in Light, Dark, Glass light, Glass dark and Solid dark. You can open each step file directly at 1:1 (720×630) and switch theme with `?theme=dark`, `&t=glass` or `&t=solid`. **No PNGs were rendered.** The only headless browser available needs a Playwright Chromium download, and this phase doesn't allow installs. The HTML uses rough SVG stand-ins for SF Symbols, and `-apple-system` approximates SF Pro.

---

## 1. Thesis and story arc

TinyStats lives in the menu bar, so the menu bar should be the protagonist of the tour, not a thumbnail on the first page. Every step opens on a **stage**: one large graphic that shows the menu bar, or what it leads to, at the moment that step is about. The controls under the stage are few, and they sit flush with the stage's edges. The story runs: **see it → make it yours → it remembers, locally → online only if you say so → here's where everything lives.** It ends on the same menu bar it started with, now showing where a click and a right-click go.

Design principles (huashu critique, applied before drawing):

| Principle | Rule in this design |
|---|---|
| Hierarchy | One headline per step (24pt; 34pt on Greet). One stage. At most one 13pt line + one 11pt line per card. |
| Density | Each step is about 70% graphic by area. No step has more than 3 visible 11pt lines outside the stage. |
| Rhythm | The same skeleton every step: title 28 → stage at 80 → controls → bottom edge at 526 → status 551 → nav 578. The stage **flexes** to fill the height, so no step has dead space. |
| Graphic-first | Every step has a stage graphic, built from real renderers (`MenuBarPreviewView`, module glyphs, `modulePalettes`) and bounded fixtures. |
| Mac utility taste | Native push buttons, `NSSwitch` (`SystemSettingSwitch`), system accent only on controls and selection, neutral text, candy only on module identity glyphs and module series. |

## 2. Direction gate (huashu: three directions, Chen picks)

| | Direction | Idea | Verdict |
|---|---|---|---|
| **A** | **Magnified menu bar** (recommended; fully specified below) | A 1× mini menu bar with a "lens" outline, zoomed into a large readout strip. The zoom motif repeats on Menu Bar, and Ready returns to the bar with a click popover and a right-click menu. | Specific to this product, honest (example readings are labelled), and directly teaches where TinyStats lives. |
| B | Quiet native sheet | Setup Assistant style: centred icon and headline, then a grouped list of three rows. | Safe and Apple-like, but generic. It loses "graphic-first" because it's a text list with icons. |
| C | Candy constellation | The app icon orbited by 7 candy module bubbles, with a giant slogan. | The most "dopamine", but it's decoration with no teaching value, and colour dominates. It's the over-styled option of the three. |

If Chen picks B or C, only §5 Step 1 and the stage graphics change. The skeleton, behaviour mapping and acceptance criteria still apply. Record Chen's choice in `design-mockups/direction-approved.md` before implementation.

## 3. Step count and order: **5 steps** (was 6)

| # | Step | Title (headline) | Was |
|---|---|---|---|
| 1 | Greet | **Your Mac, at a glance.** | Greet |
| 2 | Menu Bar | **Make the menu bar yours** | Menu Bar |
| 3 | History | **History stays on this Mac** | History (moved up from 5) |
| 4 | Online | **Online only when you choose** | Online |
| 5 | Ready | **Ready when you are** | Ready, and **absorbs Home** |

Why:

- **Home is merged into Ready.** Both taught "where details live" (holistic: Sequence §2). Ready's stage now shows the click popover with its module rail, with all 7 candy glyphs plus Overview and Sensors. That *is* "a home for every reading", as one picture instead of a 2×3 tile grid of buttons that look clickable but aren't. "Open Overview…" moves to Ready, under the popover sketch it belongs to. The "More modules…" disclosure, the duplicate History tile and the duplicate thermometer glyph are gone (holistic Step 3 items).
- **History comes before Online** (holistic backlog #6). Local choices come first, then the single place where you can choose to go online, then done.
- **We stop at 5.** Merging History into Online would bring back the dense text that round 1 removed (holistic agrees).

Consequences: `--preview-onboarding-step` accepts **1…5** (out-of-range values still fall back to 0). The progress shows "Step N of 5". Gallery file names become `welcome-step-{1…5}-{greet,menubar,history,online,ready}-{light,dark}.png`.

## 4. Shared chrome

All coordinates are in the fixed **720×630** content view. "top" is measured downward from the top edge; AppKit `y = 630 − top − height`.

```
┌──────────────────────────────────────────────────────────────── 720 ─┐
│ 28  Title 24pt semibold (x30, w560, h30)                             │
│ 80 ┌──────────────────────── STAGE (flex) ────────────────────────┐  │
│    │                                                              │  │
│    └──────────────────────────────────────────────────────────────┘  │
│        16pt gap                                                      │
│    ┌──────────────────── CONTROLS (intrinsic) ────────────────────┐  │
│526 └──────────────────────────────────────────────────────────────┘  │
│551  status line 11pt secondary (x30, w420, h14)                      │
│578  [ Skip ]           ● ━━ ● ● ●             [ Back ] [  Next  ]    │
│610                                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

| Element | Frame / rule | Type and colour |
|---|---|---|
| Window | 720×630, unchanged style mask, title "Welcome to TinyStats" | `WelcomeBackgroundView` + one `GlassSurface` (unchanged) |
| Title (`heading`) | Steps 2–5: x30, top 28, w560, h30 (AppKit y572). Greet: see §5.1 | 24pt semibold, `labelColor`, leading |
| App icon | **Greet only**: 80×80 centred (x320, top 74 / y476). Hidden on steps 2–5 | Brand icon, unchanged asset |
| Body | x30…690. Top = 80 (y550). **Bottom pinned exactly** to 104 from the window bottom (y104, top 526). Height 446. Spacing 16 between stage and controls | `NSStackView` vertical. The stage has low vertical hugging/compression so it absorbs the slack |
| Stage | A view per step (§5), drawn with `SystemStyle.drawPlatter(onGlass: true, environment:)`, corner `Radius.platter` | Draws its content **centred vertically** within its flexed height |
| Status (`message`) | x30, top 551, w420, h14 (y65). Single line, no wrapping | 11pt `secondaryLabelColor` / `glassSecondaryLabel` |
| Progress dots | Centred at x360 in the nav row (centre y36). 5 dots, 6×6, gap 7. The current dot is an 18×6 capsule | Current = `labelColor`. Others = `tertiaryLabelColor`. **Not** accent: accent is reserved for controls |
| Skip | x30, y20, w96, h32, rounded push | Hidden on step 5 |
| Back | Trailing group, `next.minX − 10`, w96 | Hidden on step 1 (not just disabled) |
| Next / Get Started / Finish | Trailing at x690, h32. w96, or w112 for "Get Started" | The default button (`keyEquivalent "\r"`) → accent in a key window |

### 4.1 Primary action (holistic A1, item 1)

- `next` stays the window's default button (`keyEquivalent = "\r"`). This draws the system accent **only while the window is key**, which is the correct platform behaviour. Don't fake it with `bezelColor`.
- The real issue is that the window may not be key. In `AppDelegate.showWelcome` (or wherever the controller is presented), call `NSApp.activate()` (14+: `NSApp.activate(ignoringOtherApps: true)` fallback) before `showWindow`, then `window.makeKeyAndOrderFront(nil)`. A menu-bar agent app doesn't activate by default, which is why every render shows a grey Next.
- Gallery renders aren't key windows, so they will still show grey. Acceptance for this item is a **live** screenshot with the window key.
- Labels: Step 1 "Get Started", steps 2–4 "Next", step 5 "Finish". AX labels are unchanged: "Next welcome step" on steps 1–4, "Finish welcome tour" on step 5.

### 4.2 Status line (holistic item 5: footer repetition)

| Step | Idle text | Replaced by (existing messages) |
|---|---|---|
| 1 Greet | *(empty)* | nothing |
| 2 Menu Bar | "Changes apply right away. Skip keeps them." | "Menu bar choices saved." / "Keep at least one readout enabled so TinyStats stays accessible." |
| 3 History | "Changes apply right away. Skip keeps them." | History toggle: On → "History will be kept between launches." Off → "History paused. Saved data stays until you clear it in History & Storage." |
| 4 Online | *(empty)* (this step has no in-place choices) | nothing |
| 5 Ready | "Changes apply right away." (Skip is hidden) | The ServiceManagement string returned by `setLoginEnabled` (unchanged) |

### 4.3 Keyboard and AX

- Return → Next/Get Started/Finish. ⌘[ → Back. Esc → Skip. On step 5, where Skip is hidden, **Esc closes the window** through `cancelOperation(_:)` on the window. That is equivalent to Finish, because choices apply immediately. Inside an open popup menu, Esc still closes the menu first (native behaviour).
- The **keycap row is removed** from the layout. Put the shortcuts in the AX help and tooltips of the nav buttons: Next "Return", Back "⌘[", Skip "Esc".
- Progress dots: one AX element, role `.staticText` (or `.progressIndicator` with value N/5), label "Step N of 5". The dot shapes are decorative.
- On every step change, post `NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: "Step N of 5, <title>", .priority: NSAccessibilityPriorityLevel.high.rawValue])` in addition to the existing `.layoutChanged` (holistic a11y gap).
- Initial first responder stays `next` on every step.
- Stage graphics are decorative (`setAccessibilityElement(false)` on children). Each stage container is **one** AX image/group with the spoken description listed in §5.

### 4.4 Treatments (glass / legacy / solid)

These are unchanged from round 3 and apply to every stage, card and chip:

- **macOS 26+, default:** one window-wide `GlassSurface`. Window `isOpaque = false`. Stages and cards use `cardFill(onGlass: true)` (translucent neutral). Secondary ink is `glassSecondaryLabel`.
- **macOS 14–25:** previous semantic window background; `platterFill` cards.
- **Reduce Transparency / Increase Contrast:** `.solid` → `controlBackgroundColor` cards, full-strength `separatorColor` hairlines.
- **New in v2:** the popover and context-menu *sketches* on Ready, and the "lens" outline, draw with `windowBackgroundColor` (sketch fill) and `separatorColor` (outline). The sketches get a 0.14 black shadow, 8pt y-offset and 24 blur, **only when not `.solid`**. They are never glass. One glass layer remains the rule.
- Candy (`SystemStyle.moduleAccent`) is used **only** on module glyphs, module chart series and module icons inside sketches. Everything else is neutral or system accent.

## 5. Steps

Shared measurements: the body is 660 wide. "Card" means `WelcomeTileView`-style platter, 16pt padding, corner `Radius.platter`. Captions are 11pt secondary. Card titles are 15pt semibold. Body text is 13pt.

### 5.1 Step 1 · Greet

**Purpose:** delight, plus the one-sentence promise. No choices on this step.

```
                        ┌────────┐
                        │  t.    │ 80pt app icon (top 74)
                        └────────┘
                  Welcome to TinyStats          15pt medium secondary (top 166, h19)
                Your Mac, at a glance.          34pt bold labelColor (top 188, h41)
 ┌───────────────────────────── stage 660×196 (top 249) ───────────────────────────┐
 │▔▔▔ ▔▔ ▔▔▔ ▔▔ (ghost menus)                          ╭CPU MEM ↑128KB/s╮  ← 1× bar │ h28
 │                    ╲____________________________________╱  zoom lines            │
 │              ╭─────────────────────────────────────────╮                         │
 │              │  CPU      MEM       ↑ 128 KB/s           │  2× readouts (h64)      │
 │              │  42%      68%       ↓ 2.4 MB/s           │                         │
 │              ╰─────────────────────────────────────────╯                         │
 │                 [cpu]     [mem]       [globe]           30pt candy glyphs        │
 │                  CPU      Memory      Network           12pt labelColor          │
 │                                                          Example readings (11pt) │
 └──────────────────────────────────────────────────────────────────────────────────┘
        ⌂ Local-only by default    ◎ No account · No analytics    ❦ Tiny footprint     12pt secondary (top 467)
 [ Skip ]                          ━ ● ● ● ●                         [ Get Started ]
```

- **Headline swap:** the slogan *is* the headline. `heading` shows "Your Mac, at a glance." at 34pt bold, centred, frame x30 w660 top 188 (y401) h41. A new root label `greeting`, "Welcome to TinyStats", sits above it at 15pt medium secondary, centred, top 166 (y445) h19, hidden on steps 2–5. The window title already says "Welcome to TinyStats". The ratio is 34:15 = 2.3×, so the squint test passes (holistic Step 1 "slogan competes").
- **Stage (`WelcomeHeroView`, reworked)**, 660×196:
  - **1× bar**: a strip flush with the stage's top, h28, fill `labelColor` 5%, top corners matching the platter. On the left are 3–4 **ghost menus**: neutral rounded bars, 7pt tall, widths 34/26/30/22, `tertiaryLabelColor` at 55%, standing in for other apps' menus. **Remove the "tinyStats" wordmark** (holistic: implies an app menu). On the right is a real `MenuBarPreviewView` at native height (`NSStatusBar.system.thickness`), trailing inset 14, with CPU/MEM/NET from `MenuBarStyleExample.readout`.
  - **Lens**: a 1pt `tertiaryLabelColor` rounded rect (r6) around the 1× readouts, inset −4.
  - **Zoom lines**: two 1pt lines at `labelColor` 14% from the lens's bottom corners to the top corners of the 2× strip.
  - **2× strip**: a second `MenuBarPreviewView` with the same readouts, drawn at **2×** by placing it in a container whose `bounds` is half its `frame` (`container.setBoundsSize(frame.size / 2)`). Centred horizontally, top 48 within the stage, strip h64, r14, `labelColor` 5% fill, horizontal padding 26.
  - **Identity row**: under each 2× readout, centred on that readout's **midX** (from `preview.renderers` frames ×2), a 30pt candy glyph, a 6pt gap, then the module title at 12pt `labelColor`. This ties each glyph to its reading (holistic Step 1 "glyphs aren't tied"), without data-flow connectors.
  - Caption "Example readings", 11pt secondary, bottom-trailing inset 14/10.
  - AX: one element, label "Example menu bar: CPU 42%, Memory 68%, Network upload 128 KB/s, download 2.4 MB/s. Example readings."
- **Trust chips**: the three existing chips, centred as a row, spacing 28, glyph 15, text 12pt secondary. Top 467 (y145).
- **Vertical centring:** the block from icon to chips (411pt) is centred between top 0 and the nav top 560 → icon top 74. Keep these fixed numbers. Don't compute them at runtime.
- **Removed from Greet:** the keycap row, the replay hint (moved to Ready), the status line, and the Back button.
- Glass: the stage is a translucent platter over the gradient, and the 2× strip uses the same 5% label tint, so it reads as a lens and not a second card.

### 5.2 Step 2 · Menu Bar ("Make the menu bar yours")

**Purpose:** choose readouts, layout and a style, with an honest live example.

```
 Make the menu bar yours
 ┌─────────────────────── stage (flex ≈164) ────────────────────────┐
 │▔▔▔ ▔▔ ▔▔▔ (ghosts)                       ╭CPU MEM NET…╮  1× bar │
 │                ╲__________________________╱                      │
 │          ╭───────────────────────────────────────╮               │
 │          │ CPU 42%   MEM 68%   ↑128 KB/s ↓2.4 MB/s│ 1.5× (h48)    │
 │          ╰───────────────────────────────────────╯               │
 │ Example readings · ⌘-drag readouts in the menu bar to reorder  [▮▮▮|▭] │
 └──────────────────────────────────────────────────────────────────┘
 [CPU      ✓][Memory   ✓][Network  ✓][Power      ]    4 columns × 2 rows, 159×38 each, gap 8
 [Time       ][Weather    ][Disks      ][+ More readouts…]  ← dashed, navigation only
 🔒 Showing Weather does not turn on forecasts.                     11pt secondary
 Style for [cpu CPU ⌄]                                              13pt + popup
 [▭][▭][▭][▭][▭][▭][▭]                                              7 columns, h52 tiles
 [▭][▭][▭][▭][▭][▭]
 Changes apply right away. Skip keeps them.
```

- **Stage** (`WelcomeMenuBarStageView`, new): the same zoom motif as Greet, so the user sees it twice and learns it.
  - 1× bar (h28) with ghosts, plus a real `MenuBarPreviewView` of **the user's current `settings.readouts`** (including advanced readouts saved in Settings), trailing. A lens outlines it.
  - Magnified preview: a second `MenuBarPreviewView`, scale `s = min(1.5, 612 / preferredWidth)`. If `s < 1`, show it at 1× inside the existing horizontal `NSScrollView` (autohiding scroller), centred, top 44, strip h `thickness × s + 12`.
  - **Example readings, not dashes** (holistic item 3): build groups from `MenuBarStyleExample.readout(module:style: settings.style(for:), settings:)`. For `.battery`, pass no `batteryState`. Respect `settings.separateItems` exactly as `updatePreview` does now. Remove `previewSnapshot = Snapshot()`. No sampler, no live data.
  - Foot row inside the stage, inset 14, bottom 12: caption "Example readings · ⌘-drag readouts in the menu bar to reorder" (11pt secondary, leading). The existing `MenuBarLayoutIcons.control()` segmented control sits trailing (AX "Menu bar layout").
  - AX: the stage is a group labelled "Menu bar preview with example readings". The segmented control and scroll view stay reachable.
- **Readout chips:** the 7 existing `WelcomeReadoutButton`s in a **fixed 4-column grid** (each `(660 − 3×8)/4 = 159` wide, h38, gaps 8). Don't use `.fillEqually` per row. Use an `NSGridView`, or two rows of 4 with an explicit width constraint per cell (holistic Step 2 chip widths).
  - The 8th cell is a new **"More readouts…"** chip: dashed 1pt `tertiaryLabelColor` rim, transparent fill, `plus` glyph in secondary, 12pt secondary title. It is a push button (AX role button, label "More readouts in Menu Bar settings") → `onMenuBarSettings`. It's navigation only, and it fills the orphan slot with a real route to GPU, Sensors and so on.
- **Weather note**, unchanged in meaning: "Showing Weather does not turn on forecasts." 11pt secondary, leading, with a 12pt `lock` glyph, 8pt below the chips.
- **Style row:** the label "Style for" (13pt) plus the existing `styleModuleSelector` popup. Each popup item has a 14pt candy module glyph image. The popup's AX label stays "Welcome readout to customize". **Behaviour change (UI only):** when a readout chip is switched **on**, `styleModule` follows that chip and the popup updates. This matches Settings, where selecting a chip selects its module (holistic Step 2). Switching a chip off doesn't move the style target.
- **Style grid:** the existing `MenuBarStylePicker`, full width, top 10 below the style row. Ask the picker for **52pt tile height** if it exposes a size, otherwise keep its default. Picture tiles must use `SystemStyle.cardFill(onGlass: true, environment:)`, like the chips (holistic glass "style tiles look solid").
- Stage height = 446 − 16 − controls (≈266) ≈ 164. The stage centres its content, so there's no dead space on this step either.

### 5.3 Step 3 · History ("History stays on this Mac")

**Purpose:** confirm local history (on by default) and say clearly that alerts are off.

```
 History stays on this Mac
 ┌────────────────────────── stage (flex ≈262) ───────────────────────────┐
 │ [cpu] CPU   [mem] Memory                                               │
 │   ╱╲    ╱╲_╱╲      ╱╲    ← CPU series, candy, 2pt + area fill          │
 │ ──────────────────────── ← Memory series, candy, 2pt                   │
 │ 28 days ago                                                       Now  │
 │ Example history                       ⛁ Saved locally · up to 8.2 MiB │
 └────────────────────────────────────────────────────────────────────────┘
 ┌──────────── History (325×168) ─────────┐ ┌──────────── Alerts ─────────────────────┐
 │ ⟲  Keep history                  (●━)  │ │ 🔔 Alerts                         [Off] │
 │    On by default · 28 days, only on    │ │    Off until you turn them on and allow │
 │    this Mac                            │ │    them                                 │
 │                                        │ │    ⌜cpu CPU above 90% for 5 min · example⌟│
 │                 [⛁ History & Storage…] │ │                     [🔔 Alert Rules…]   │
 └────────────────────────────────────────┘ └─────────────────────────────────────────┘
 Changes apply right away. Skip keeps them.
```

- **Stage** (`WelcomeHistoryStageView`, new):
  - Legend top-left, inset 18/16: CPU glyph 15 + "CPU", Memory glyph 15 + "Memory" (12pt `labelColor`, spacing 16).
  - Chart from inset 18 to the bottom, minus 44. Two series from a **bounded static fixture**: `WelcomeFixture.historyCPU` and `.historyMemory`, 56 `Double`s each, as `static let` constants. They mirror the mockup formula; values 0…100. Strokes use `moduleAccent(.cpu)` and `moduleAccent(.memory)`. Stroke width and fill follow existing chart tokens: 2pt stroke on glass, 1.5pt elsewhere; CPU area fill at 6% on glass, 20% elsewhere. Gridlines at 25/50/75% use `labelColor` at 8%.
  - Axis labels "28 days ago" (leading) and "Now" (trailing), 11pt secondary.
  - Foot: "Example history" (leading). On the trailing side, a `internaldrive` glyph 12 and "Saved locally · up to 8.2 MiB" (11pt secondary). **Derive "8.2 MiB" and "28 days" from the same constants** the current tour uses (`≤8.2 MiB` / `28 days`). Don't hard-code new numbers.
  - AX: one image element: "Example history chart: CPU and Memory over 28 days. Saved locally, up to 8.2 MiB."
- **History card** (left, 325×112, `identifier "welcome-history"`):
  - Title row: `clock.arrow.circlepath` 28pt neutral glyph; "Keep history" 15pt semibold; trailing **`SystemSettingSwitch(title: "Keep history between launches")`** with AX label "Keep history between launches". Its action is `historyChanged`. It's disabled while `historyBusy`. Its state is `currentSettings().persistHistory`.
  - Caption (indent 38): "On by default · 28 days, only on this Mac".
  - Bottom-trailing: push button "History & Storage…" with symbol `internaldrive` → `onHistory`.
  - The old static line "Off keeps the file. Clear it in History." moves to the **status line**, shown only after switching Off (§4.2), and into the switch's AX help: "Turning off keeps saved data. Clear it in History & Storage."
- **Alerts card** (right, `identifier "welcome-notifications"`):
  - Title row: `bell.badge` 28pt neutral; "Alerts" 15pt semibold; trailing a **read-only state badge** that reads `currentSettings().alerts`: "On" or "Off" (10pt medium secondary, 0.5pt `tertiaryLabelColor` capsule). This is not a control.
  - Caption: "Off until you turn them on and allow them" when Off; "On · Review rules and notification access" when On (also refreshed on replay).
  - **Example rule chip:** dashed capsule, CPU glyph 13 (candy), then "CPU above 90% for 5 min" in `labelColor` 11pt, then " · example" in secondary. It's decorative, and its AX label is "Example rule: CPU above 90% for 5 minutes". It replaces the empty band and the "Your rules. Your thresholds." line (holistic Step 5).
  - Bottom-trailing: "Alert Rules…" with symbol `bell` → `onNotifications`. AX help: "Editing rules alone does not turn on alerts."
- Both cards pin their button to the bottom-trailing corner and top-align their copy. The compact History card is 112pt tall; the Alerts card remains 168pt to fit its example chip. Their top edges align (Fix round 1).
- Glyph rule (holistic cross-cutting): the **28pt** card-glyph size is shared by every card on steps 3–5. Stage glyphs are 30–40pt. That's two sizes in the tour, as recommended.

### 5.4 Step 4 · Online ("Online only when you choose")

**Purpose:** show that both online features are off and where data would go. The setup buttons only open editors.

```
 Online only when you choose
                                     ┌──────── Weather (350×154) ───────────────┐
                               ┄┄┄┄┄▶│ ☁ Weather                                 │
      ╭───────────╮      ┄ [Off] ┄   │   MET Norway · api.met.no                  │
      │  💻       │ ┄┄┄              │   Sends rounded location and your IP       │
      │ This Mac  │                  │   Pick a city or allow location in setup   │
      │ Local first│ ┄┄┄             │                     [⚙ Set Up Weather…]    │
      ╰───────────╯      ┄ [Off] ┄   └──────────────────────────────────────────┘
                               ┄┄┄┄┄▶┌──────── Internet checks ─────────────────┐
                                     │ 🌐 Internet checks  (Advanced)           │
                                     │   Apple or your URL · ipify · your ping  │
                                     │   address                                │
                                     │   Each destination sees your IP          │
                                     │   Review destinations and timing first   │
                                     │                      [⚙ Review Checks…]  │
                                     └──────────────────────────────────────────┘
                 🔒 Off until you turn them on. Opening setup changes nothing.
```

- The **whole body is the stage** (`WelcomeOnlineStageView`, new). There's no platter behind the diagram; the window background shows through, and only the nodes are platters/cards. This step has no separate controls zone.
  - **This Mac node:** 150×150 circle platter at stage x20, centred vertically (top ≈135 in a 446 body). It contains a `laptopcomputer` glyph (40pt neutral), "This Mac" (14pt semibold) and "Local first" (11pt secondary).
  - **Destination cards** (each 350×154, x310): Weather at top 20, Internet checks at top 240. Inside each: candy glyph 32 (`.weather` / `.network`), title 15pt semibold, and lines indented 42. The **first line** is the destination in `labelColor` 11pt. The next lines are 11pt secondary. The button sits bottom-trailing.
  - **Links:** two cubic Béziers from the Mac node's right edge to each card's left edge. 1.5pt stroke, `labelColor` 35%, dash pattern [4, 5]. An **"Off" pill** (10pt semibold secondary, capsule with `windowBackgroundColor` fill and 0.5pt separator rim) sits at each curve's midpoint. Dashed + "Off" = not connected. This is an honest data-flow diagram of a disabled state, so it doesn't conflict with the round-3 "no implied connectors" rule on Greet.
  - **Promise line**, centred at the stage bottom: `lock` 13 + "Off until you turn them on. Opening setup changes nothing." (12pt secondary, single line). This replaces both "Opening setup enables nothing" lines (holistic item 5).
- Weather card (`identifier "welcome-weather"`): lines are "MET Norway · api.met.no", "Sends rounded location and your IP" and "Pick a city or allow location in setup". Button "Set Up Weather…", symbol `slider.horizontal.3`, AX label "Set up Weather" → `onWeather`. Keep the existing AX help text verbatim.
- Internet card (`identifier "welcome-internet"`): title "Internet checks" plus an "Advanced" badge (same badge style as Alerts). Lines are "Apple or your URL · ipify · your ping address", "Each destination sees your IP" and "Review destinations and timing first". Button "Review Checks…", symbol `slider.horizontal.3` (not `arrow.up.right`), AX label "Review Internet checks" → `onInternet`. Keep the existing AX help text.
- The "Off" pills describe new installs only. On replay they must reflect saved state, read from `currentSettings()` and never written: Weather is On when `settings.weather.enabled`; Internet checks are On when `settings.connectivityChecks || settings.publicIPChecks || settings.pingCheck.enabled`. An On pill reads **"On"** and its link draws **solid** at `labelColor` 35%. The promise line then reads "Turn each off in its own setup. Opening setup changes nothing." when either is on.
- AX: the stage group label is "Online features. Weather and Internet checks are off until you turn them on." The cards and buttons are separate elements.

### 5.5 Step 5 · Ready ("Ready when you are")

**Purpose:** teach the two gestures, show where everything lives (absorbing Home), give the replay route, and offer Launch at login.

```
 Ready when you are
 ┌─────────────────────────── stage (flex ≈370) ────────────────────────────────┐
 │▔▔▔ ▔▔ ▔▔▔ ▔▔                                 [CPU] MEM [NET]       ← 1× bar  │ h28
 │                  ╭────────▲───────────────╮   ┌────────────────────────┐     │
 │                  │ ▦ │ CPU                │   │ Pause monitoring       │     │
 │                  │ ● │ 42%                │   │ Settings…           ⌘, │     │
 │                  │ ● │ ╱╲_╱╲╱╲ (cpu)      │   │▐Show welcome tour     ▌│ ← accent highlight
 │                  │ ● │ ▬▬▬▬▬▬            │   │ Open Activity Monitor  │     │
 │                  │ ● │ ▬▬▬▬               │   │ ────────────────────── │     │
 │                  │ ● │ ▬▬▬▬▬              │   │ Quit TinyStats      ⌘Q │     │
 │                  │ ● │                    │   └────────────────────────┘     │
 │                  ╰────────────────────────╯                                  │
 │ ↖ Click a readout                [Open Overview…] ▤ Right-click     [Settings…]│
 │   Details for every reading                         Settings, pause, replay this tour│
 └──────────────────────────────────────────────────────────────────────────────┘
 ┌──────────────────────────── 660×60 ──────────────────────────────────────────┐
 │ ⏻  Launch at login                                                    (━●)  │
 │    Login Items may need macOS approval                                       │
 └──────────────────────────────────────────────────────────────────────────────┘
 Changes apply right away.
                                   ● ● ● ● ━━                  [ Back ] [ Finish ]
```

- **Stage** (`WelcomeReadyStageView`, new; replaces the 3 tiles on Ready and all of Home):
  - **1× bar** (h28) with ghosts on the left. A real `MenuBarPreviewView` with the example CPU/MEM/NET sits right of centre (trailing inset ≈44), so the sketches hanging from it fit. The CPU and NET readouts each get a **hover plate** (`labelColor` 12%, r4) to show which readout each sketch belongs to.
  - **Popover sketch:** 250×200, top 40, placed left of the context-menu sketch with a 16pt gap. A short neutral guide connects the CPU readout to its 12pt notch, preserving native readout packing (Fix round 1). Fill `windowBackgroundColor`, r12, 0.5pt separator, shadow (§4.4).
    - Left **module rail**, 40 wide, hairline divider: 15pt glyphs for Overview (`square.grid.2x2`, neutral), then CPU, Memory, Disks, Network, Power, Time and Weather (all candy), then Sensors (candy). CPU has a neutral 10% selection plate.
    - Right pane, inset 14/12: "CPU" 12pt semibold; "42%" 26pt bold `labelColor` (from `MenuBarStyleExample` CPU value); a 180×40 sparkline from `MenuBarStyleExample` `values` ([18, 24, 21, 36, 32, 48, 40, 54, 38, 42]) in CPU accent with a 10% fill; three neutral placeholder bars (7pt, `labelColor` 5%).
    - This one picture replaces the six Home tiles. The rail shows every module's home and its candy identity.
  - **Context-menu sketch:** 172 wide, top 34, left edge at the NET readout's minX. Fill `windowBackgroundColor`, r8, padding 5, 21pt rows, 12pt text. The rows mirror `AppDelegate.statusClicked` **exactly**: "Pause monitoring" · "Settings… ⌘," · **"Show welcome tour"** (selected: `controlAccentColor` fill, `alternateSelectedControlTextColor` text; this is the replay hint, moved here) · "Open Activity Monitor" · separator · "Quit TinyStats ⌘Q".
    - **Anti-drift:** extract those titles into a small `StatusMenuTitles` enum (static strings) used by both `AppDelegate` and this sketch, plus a test that asserts they're equal. This is a trivial refactor, and it's the one Swift change outside the welcome files.
  - **Tips row**, inset 18, bottom 14, two equal columns:
    - Left: `cursorarrow.click` 22 neutral; "Click a readout" 13pt semibold; "Details for every reading" 11pt secondary; trailing button "Open Overview…" (`square.grid.2x2`) → `onOverview`.
    - Right: `contextualmenu.and.cursorarrow` 22 neutral (fallback `cursorarrow.and.square.on.square.dashed` on older SDKs); "Right-click" 13pt semibold; "Settings, pause, replay this tour" 11pt secondary; trailing button "Settings…" (`gearshape`) → `onSettings`.
  - **"Open Menu Bar settings…" is removed from Ready.** It repeated step 2, which now has "More readouts…" (holistic Step 6).
  - AX: one element, label "Illustration: click a readout to open its details, with a sidebar for every module. Right-click a readout for Pause monitoring, Settings, Show welcome tour, Open Activity Monitor and Quit TinyStats." The two buttons are separate elements.
- **Launch at login row**: a card, 660×60, padding 18, separate from the stage (holistic item 4). It contains a `power` glyph (22 neutral), "Launch at login" (13pt semibold) and the caption "Login Items may need macOS approval". Trailing: **`SystemSettingSwitch(title: "Launch at login")`**, AX label "Launch at login" → `loginChanged` → `setLoginEnabled`. State comes from `loginEnabled()` and is refreshed on `windowDidBecomeKey` (unchanged).
- Nav: **Skip hidden**, Back visible, Finish is the default button (holistic item 5). Esc closes the window (§4.3).

## 6. How each holistic item is resolved

| Holistic item | Resolution |
|---|---|
| 1. Next/Finish must read as the primary action | Default button stays; the window is activated and made key on presentation (§4.1); Back is hidden on step 1 and Skip on step 5, so the accent button is the only filled control in the nav row. Live-window verification is an acceptance item. |
| 2. Empty vertical space | Fixed skeleton with a **flexing stage** pinned between top 80 and bottom 526 on steps 2–5. Greet is a centred composition. Online is a full-body diagram. No step leaves more than 24pt of gap above the status line. |
| 3. Step 2 preview dashes | The preview uses `MenuBarStyleExample` for the user's actual readouts and styles, captioned "Example readings" (§5.2). |
| 4. Trailing controls | Every card pins its action to the bottom-trailing corner. Switches sit at the trailing edge of the title row. "More modules…" is gone. Launch at login has its own row with a trailing switch. |
| 5a. Keycap developer strip | Removed. Shortcuts move to tooltips and AX help (§4.3). |
| 5b. Redundant footer on greet | Status line is empty on Greet and Online. Elsewhere it's shorter, and real status messages replace it (§4.2). |
| 5c. Skip on last step | Hidden. Esc still closes. |
| 5d. Duplicate "enables nothing" | Stated once, as the Online promise line. |
| 5e. Replay hint on Greet | Moved to Ready, *shown* as the highlighted "Show welcome tour" item in the right-click sketch, plus "replay this tour" in its tip caption. |
| Other review notes absorbed | Step-3 tiles that look clickable but aren't → removed (merged). Duplicate thermometer glyph → removed. `arrow.up.right` on Review → `slider.horizontal.3`. AX "Internet checks" → "Review Internet checks". "Advanced · Internet checks" title imbalance → title plus badge. Notifications empty band → example rule chip. "Off keeps the file" wording → contextual status message. Step-change announcement → added. Chip widths → fixed 4-column grid. Glass style tiles → `cardFill(onGlass:)`. Glyph sizes → two tiers (28 cards / 30–40 stages). Two ways to pick a style module → the target follows the chip that was just switched on. |

## 7. Behaviour mapping (UI control → existing callback/setting)

| Step | Control | Wiring | Setting effect |
|---|---|---|---|
| all | Skip | `skipTour` → `close()` | none |
| all | Back (⌘[) | `previousStep` | none |
| all | Next / Get Started / Finish (Return) | `nextStep`; step 5 → `close()` | none |
| 5 | Esc (Skip hidden) | `cancelOperation` → `close()` | none |
| 2 | 7 readout chips | `menuChanged` → `onMenuBarChange(settings)`; keeps ≥1 readout and saved advanced readouts (unchanged logic) | `settings.readouts`, `styles` |
| 2 | More readouts… chip | **`onMenuBarSettings`** (existing; now used here instead of on Ready) | none |
| 2 | Layout segmented control | `presetChanged` → `onMenuBarChange` | `settings.separateItems` |
| 2 | Style for popup | `styleModuleChanged` (UI only) | none |
| 2 | Style picker tiles | `menuChanged` | `settings.styles[module]` |
| 3 | Keep history switch | `historyChanged` → `onHistoryPersistence(Bool)` → existing worker path; disabled while busy | `persistHistory` |
| 3 | History & Storage… | `openHistory` → `onHistory` | none |
| 3 | Alert Rules… | `openNotifications` → `onNotifications` | none (opening rules enables nothing) |
| 3 | Alerts On/Off badge | reads `settings.alerts` | none (read-only) |
| 4 | Set Up Weather… | `openWeather` → `onWeather` | none (editor opens; enabling stays in the editor) |
| 4 | Review Checks… | `openInternet` → `onInternet` | none |
| 4 | Off/On pills | read `weather.enabled`; `connectivityChecks \|\| publicIPChecks \|\| pingCheck.enabled` | none (read-only) |
| 5 | Open Overview… | `openOverview` → `onOverview` | none |
| 5 | Settings… | `openSettings` → `onSettings` | none |
| 5 | Launch at login switch | `loginChanged` → `setLoginEnabled(Bool)` (shared ServiceManagement path) → status line shows result | Login Item |
| — | `onMenuBarSettings` on Ready | **removed from Ready** (moved to step 2) | — |

Unchanged invariants: `WelcomePresentation` logic and keys (except the preview step range 1…5); the `hasShownWelcome` flag is recorded before presentation and never by previews; replay via the app or right-click menus ("Show welcome tour"); the tour adds no preference keys, timers, collectors, network calls or permission requests; `windowDidBecomeKey` refreshes all mirrored state.

## 8. Components: reuse and new

| Component | Status |
|---|---|
| `WelcomeBackgroundView`, `GlassSurface`, `SystemStyle.drawPlatter/cardFill/moduleAccent/glassSecondaryLabel` | Reuse as is |
| `MenuBarPreviewView`, `MenuBarStyleExample.readout`, `MenuBarLayoutIcons.control()`, `MenuBarStylePicker` | Reuse. The picker may get an optional tile height |
| `WelcomeReadoutButton` | Reuse (in a fixed grid) |
| `SystemSettingSwitch` | Reuse for Keep history and Launch at login (matches Settings and History) |
| `WelcomeTileView` | Reuse as the card base for steps 3–5. Add an optional trailing accessory and a bottom-trailing action slot. Drop `large`/`compact` in favour of the single 28pt glyph tier |
| `WelcomeHeroView` | Rework: 1× bar + lens + 2× strip + aligned identity row; remove the wordmark |
| `WelcomeKeycapView` | **Delete** |
| `WelcomeSectionView` | Delete if unused after step 2 moves into the stage |
| New: `WelcomeStageView` (base: platter, centred content, single AX element), `WelcomeMenuBarStageView`, `WelcomeHistoryStageView`, `WelcomeOnlineStageView`, `WelcomeReadyStageView`, `WelcomeProgressDots`, `WelcomeMoreReadoutsButton`, `WelcomeFixture` (static bounded arrays), `StatusMenuTitles` | Small AppKit views. Draw in `draw(_:)`, with no timers, animations or layers beyond the existing pattern |

No decorative animation (DESIGN.md: "No decorative animation"). Step changes stay as instant re-renders.

## 9. Copy (every visible string)

| Step | Strings |
|---|---|
| 1 | "Welcome to TinyStats" · "Your Mac, at a glance." · "Example readings" · "CPU" · "Memory" · "Network" · "Local-only by default" · "No account · No analytics" · "Tiny footprint" · "Skip" · "Get Started" |
| 2 | "Make the menu bar yours" · "Example readings · ⌘-drag readouts in the menu bar to reorder" · module titles · "More readouts…" · "Showing Weather does not turn on forecasts." · "Style for" · status strings (§4.2) · "Back" · "Next" |
| 3 | "History stays on this Mac" · "CPU" · "Memory" · "28 days ago" · "Now" · "Example history" · "Saved locally · up to 8.2 MiB" · "Keep history" · "On by default · 28 days, only on this Mac" · "History & Storage…" · "Alerts" · "On"/"Off" · "Off until you turn them on and allow them" · "CPU above 90% for 5 min" · "· example" · "Alert Rules…" |
| 4 | "Online only when you choose" · "This Mac" · "Local first" · "Off"/"On" · "Weather" · "MET Norway · api.met.no" · "Sends rounded location and your IP" · "Pick a city or allow location in setup" · "Set Up Weather…" · "Internet checks" · "Advanced" · "Apple or your URL · ipify · your ping address" · "Each destination sees your IP" · "Review destinations and timing first" · "Review Checks…" · "Off until you turn them on. Opening setup changes nothing." |
| 5 | "Ready when you are" · menu-sketch titles (from `StatusMenuTitles`) · "CPU" · "42%" · "Click a readout" · "Details for every reading" · "Open Overview…" · "Right-click" · "Settings, pause, replay this tour" · "Settings…" · "Launch at login" · "Login Items may need macOS approval" · "Changes apply right away." · "Finish" |

Every label is a single line of ≤100 characters, ≤20pt high. The only exception is the Greet slogan, at 34pt, so the test cap for it becomes ≤44pt high. Text inside drawn stages is not an `NSTextField` and isn't subject to the label test, but it must follow the same rules.

## 10. Test contract changes (for Codex; update deliberately, don't delete coverage)

- `0..<6` / `1...6` / `min(5, …)` → 5 steps. `previewInitialStep` range is 1…5.
- Gallery names and step keys: `["greet", "menubar", "history", "online", "ready"]`.
- `welcomeSloganAlignsWithHeading…` → replace with a test that the slogan is the heading, centred, 34pt bold, `labelColor`; that the greeting is 15pt secondary above it; and that the 34:15 ratio holds.
- `welcomeStarterListPresets…` asserting `value == "—"` → assert that the preview readouts equal `MenuBarStyleExample` values for the selected modules, and that **no** `Snapshot`/sampler is touched.
- `welcomeModuleCardsDiscloseSecondaryContentAndRouteOverview` → becomes "Ready routes Overview and Settings; the menu sketch titles equal `StatusMenuTitles`, and those equal the status menu".
- `welcomeFinishTeaches…RoutesMenuBar…` → Menu Bar settings routing moves to step 2's "More readouts…" chip.
- History and Login tests: the control is now `SystemSettingSwitch` (an `NSSwitch`). Find it by AX label; state semantics are unchanged.
- Step-specific counts in `welcomeGraphicSequence…`: step 2 has 7 readout buttons + 1 more-readouts button; step 3 has 2 cards (`welcome-history`, `welcome-notifications`); step 4 has `welcome-weather` and `welcome-internet`; step 5 has 1 card + the ready stage.
- Add: the Back button is hidden on step 1 and Skip on step 5. Esc on step 5 closes without changing settings. Every step posts an announcement "Step N of 5, <title>". On step 2, switching a chip on retargets the style popup.
- Add: the Online pills reflect saved state on replay (weather on → "On") and never write it.
- Keep: `bodyFrame.minY ≥ 100 && maxY ≤ 550`, all controls inside the window, labels not clipped, `detachesHiddenViews` reset between steps.

## 11. Out of scope / non-goals

- No new preference keys, analytics, accounts, legal or consent walls, timers, animation, sound, network calls, permission prompts or collectors.
- No per-step window resizing. The window stays at 720×630.
- No live sampler data anywhere in the tour. Every number comes from `MenuBarStyleExample` or `WelcomeFixture`.
- No changes to Settings, History, Weather, Internet or Rules editors, beyond extracting `StatusMenuTitles`.
- No per-module "open this pane" actions. There's no callback for them, and adding routes is out of scope. Overview is the single entry point.
- No custom glass on cards or sketches. There's no glass on glass.
- No change to the brand icon or the wordmark rules.

## 12. Acceptance checklist for design review

Renders: run `TINYSTATS_SYSTEM_RENDER_PATH` light and dark for all 5 steps, plus solid greeting pairs, plus an optional glass capture. Also take **one live key-window screenshot**.

- [ ] Step count is 5, in the order Greet → Menu Bar → History → Online → Ready. Progress shows "Step N of 5" to AX, and the dots match.
- [ ] Every step has a stage graphic that covers at least 45% of the body area (Greet: hero ≥ 196pt tall).
- [ ] No step has more than 24pt of empty band between the last control and the status line (Greet excepted: it's a centred composition).
- [ ] Greet: the slogan is the largest text in the tour (34pt). The 2× readouts are legible. Each candy glyph is centred under its own readout (±1pt). There's no wordmark in the bar, no keycaps, no status line and no Back.
- [ ] Menu Bar: the preview shows example values (no "—" for available example modules) and follows layout/style changes immediately. Chips are equal width in a 4×2 grid. "More readouts…" opens Menu Bar settings and changes nothing. Turning a chip on retargets "Style for".
- [ ] History: the switch toggles through the existing worker callback and is disabled while busy. Switching Off shows the "saved data stays" status. The Alerts badge reflects `settings.alerts`. No empty band in either card.
- [ ] Online: destinations are named (api.met.no; Apple or your URL; ipify; ping address). Pills and links read Off with dashed lines on a new install and On with solid lines when saved settings say so. Buttons only open editors. The "changes nothing" promise appears once.
- [ ] Ready: the menu sketch titles match the real right-click menu (enforced by a test). "Show welcome tour" is highlighted. Open Overview… and Settings… route correctly. Launch at login is a trailing switch in its own row. Skip is hidden. Esc closes.
- [ ] Next/Get Started/Finish render in the system accent in a **live key window** on macOS 26 and on 14–15 (if available). Back and Skip render neutral.
- [ ] Candy colour appears only on module glyphs, module series and module icons in sketches. All text is neutral. Selection uses only the system accent.
- [ ] Glass (26+) is visibly translucent with one glass layer. Legacy 14–25 matches the previous look. Reduce Transparency and Increase Contrast give solid cards, full hairlines and no sketch shadows.
- [ ] VoiceOver: each stage reads as one element with the description in §5. All controls are reachable by Tab, with labels as specified. Step changes are announced.
- [ ] Navigation alone changes no settings. Skip keeps choices. Previews don't set `hasShownWelcome`. Replay from both menus still works. At least one readout always remains.
- [ ] `scripts/verify-local.sh` passes on the final tree (implementation phase, not this design phase).
