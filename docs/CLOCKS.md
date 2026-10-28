# Menu bar clock formats

Open **Settings → Menu Bar → … beside Time**. Enable **Use custom clock formats**, choose a preset or edit the two lines, then **Save clocks**. All entries save together. Opening the editor or saving formats does not enable the Time readout; enable Time separately in Menu Bar. Revert draft restores the last saved formats. Unsaved edits survive switching clocks and unrelated parent style/theme changes.

Use **+ / −** to add or remove clocks, and **‹ / ›** to reorder them. Up to six clocks share the Time status item, including in individual-item mode. Each clock has a name, a time zone and one or two formatted lines. `local` follows the Mac's zone; `UTC` and IANA names such as `America/Los_Angeles` follow their own daylight-saving rules. Suggestions include the zones configured in General. General's world-clock list controls the Date & Time detail table independently.

The preview uses the actual status renderer, Time font, white text/clock graphics, native menu bar appearance and current date. Content windows follow General's System/Light/Dark setting. Stacked displays both lines; an empty second line uses one line. Label + value and Value only join the lines. Label only and Icon only hide formatted times. Wide previews scroll horizontally; actual available menu bar space depends on the Mac and other status items.

## Tokens

Type literal text around these named tokens, or use the token picker and Insert. Insert appends to the selected line. `{{` and `}}` produce literal braces. Names allow 48 UTF-16 units; each line allows 96. Newlines/control characters and unknown or incomplete tokens disable Save and clear the draft preview; the previous saved clocks remain intact. Unicode text, flags and compound emoji are supported. Rendered output is capped at 128 characters per line with an ellipsis.

| Tokens | Meaning |
| --- | --- |
| `{name}` | Clock name, or its zone when unnamed |
| `{systemTime}`, `{systemTimeSeconds}` | Localized system time, without/with seconds, in this clock's zone |
| `{weekday}`, `{weekdayUpper}`, `{weekdayLong}` | Localized short, uppercase short or full weekday |
| `{year}`, `{month}`, `{day}` | Numeric calendar components; year has at least four digits, month/day two |
| `{monthName}`, `{monthLong}` | Localized short or full month |
| `{hour24}`, `{hour12}`, `{minute}`, `{second}` | Explicit 24-hour/two digits, 12-hour, minute/two digits, second/two digits |
| `{period}` | Localized AM/PM |
| `{zone}`, `{offset}` | Zone abbreviation or signed UTC offset such as `+05:45` |
| `{localOffset}` | Signed difference from this Mac’s current offset, including DST in both zones |
| `{analog}`, `{analogSeconds}` | Native analogue dial without/with a second hand |
| `{calendar}` | Mini calendar containing the date’s day of month |
| `{fuzzy}` | English time rounded to the nearest five minutes, such as “quarter past five” |

Examples: `{weekdayUpper}` above `{hour24}:{minute}:{second}`, or a single line `LA {hour12}:{minute} {period}`. Numeric explicit tokens use ASCII digits; localized date words and system-time tokens follow the current locale/calendar. `{offset}` is relative to UTC; `{localOffset}` is relative to the Mac’s zone. Offset differences can exceed 24 hours across the date line. Historical offsets retain seconds when needed.

Mix graphics with text, for example `{calendar} {hour24}:{minute}`, or `{calendar} {weekday}` above `{analog} {hour24}:{minute}`. Presets include analogue, analogue with seconds, calendar + time, calendar + analogue, fuzzy time and time difference. Dials use this clock’s zone; the mini calendar uses its calendar day. Graphics fit the line height and are larger in a one-line clock. Text fonts follow Time; text, calendar outlines and dial graphics stay white with 0.35.3. Text has the shared subtle dark shadow; graphic dimensions stay fixed within a line. Since 0.35.4, shared clock entries use a 3-point gap and the Time item has 1-point side padding; see [menu bar appearance](MENU-BAR.md#font-color-and-ordering). Spoken descriptions retain the actual dial time and calendar day. Fuzzy time uses English hour names and rounds at minutes 3, 8, 13 and so on; it does not imply a precise minute reading.

Clock fields preserve literal Unicode, quotes, double hyphens and token syntax. Automatic spelling/grammar, correction, text substitutions and completion are disabled in these clock windows, without changing global text preferences. Use **⌘Z** / **⇧⌘Z** to undo/redo text edits before leaving the field.

## World-clock detail-table format

Open **Settings → General → World clock format…**. This separate format applies to all selected world-clock rows in Date & Time. Choose one of eight presets or type literal text and the text tokens listed above, then **Save format**. **Revert draft** restores the last saved format. Invalid drafts show no rows and cannot save. The preview uses the actual saved cities, production renderer, 12-point fonts, 280/230-point columns, alignment, clipping and tooltips from the detail table. Both follow the app's Light/Dark/System appearance. It does not change the menu-bar clock format or enable Time.

The table accepts text tokens, including localized system time, seconds, fuzzy time and relative offsets; analogue/calendar vector tokens remain available in the menu bar editor. The default is `{weekday} {hour24}:{minute} · {zone}`, preserving the previous display. The shared format is bounded to 96 UTF-16 units and rendered output to 128 characters. City names and zones are edited separately in General. Empty city lists remain empty, without a preview seconds request. Unsaved format drafts survive unrelated appearance and city-list changes.

## Resource behavior

One shared timer schedules hardware collection and visual clock boundaries separately. Seconds do not add hardware samples, history points or alert evaluations. Only visible seconds text or a second-hand token adds seconds demand. This includes a visible Date & Time world-clock table or its editor; seconds in saved, hidden table formats add none. Multiple open clock editors combine their demands, so closing one cannot slow another. Hidden clock formats add none. Closing the editor removes its preview demand; a visible Time readout can still require seconds. Pause/sleep stops the worker; resume resets rate baselines. Locale/zone/system-clock notifications invalidate the bounded native formatter cache. Calendar Today advances at minute boundaries without fabricating a new hardware timestamp; an explicitly selected day remains pinned.

The native formatter cache has at most twelve locale/calendar/zone entries. Each creates at most three formatters, on demand: numeric/literal clocks need none, date words share one, and localized system time with/without seconds uses a separate formatter for each. Dials/calendars use immediate native vector drawing, without cached images, layers or animation. They, fuzzy time and offsets create no DateFormatter. No clock timer, process, permission or network request is owned by the editor. Full resource measurements are recorded in PERFORMANCE.md; these constraints alone do not establish a particular memory or battery cost.

## Scope and research

Bjango's public [menu bar clock examples](https://bjango.com/help/istatmenus7/menubarclock/) document literal text, tokens, stacked lines and multiple horizontal clocks. Its [version history](https://bjango.com/mac/istatmenus/versionhistory/) identifies an analogue menu bar clock. Its [Time help](https://bjango.com/help/istatmenus7/time/) documents editable city names and world-clock formats. These describe observable behavior, not proprietary implementation. TinyStats uses its own bounded token parser and AppKit renderer; no proprietary code or assets are copied.

This feature is not full commercial clock parity. The calendar offers System default or any explicit first weekday through **Time → Calendar…** or **Settings → General → Online & Time advanced → Calendar…**; see [calendar layout](CALENDAR.md#week-layout). Physical sleep/zone/locale transitions and constrained menu bar hardware still need broader runtime validation.
