# Calendar layout and optional advanced agenda

Open **Time → Calendar…** or **Settings → General → Online & Time advanced → Calendar…**. The advanced section starts collapsed each Settings session. The account-calendar agenda is optional advanced functionality, absent from the welcome tour; the local month calendar and world clocks remain primary Time features. Opening the advanced section or Calendar settings does not enable the agenda or request permission. **Show calendar events in Date & Time** is off by default. Enabling it does not itself ask for permission. Use **Allow Calendar Access…** to request macOS access, then choose all calendars or an explicit subset. An empty subset selects none. Missing selected IDs are retained, so a temporarily unavailable calendar cannot silently change the selection to all calendars.

Open **Date & Time** and select a native day button to view that day's events. Previous/next month retain the chosen day where possible, clamping to the last valid day; Today resumes following the current date. A pinned civil day survives system time-zone changes. World clocks remain below the agenda. All-day events precede timed events, which are ordered by start/end/title. An arrow in a time range means the event extends beyond that day's boundary. Events ending exactly at midnight do not appear on the following day. Canceled events are excluded; invitations and declined events otherwise follow EventKit's returned data.

## Week layout

**First day of week** offers System default and all seven weekdays. System default follows the macOS calendar/locale, including later changes. The native month preview uses the same renderer as Time, and layout changes apply immediately. The preview starts on the day pinned in Time when opened from that context; navigating the preview alone does not change Time's pinned date. Week layout is available with events disabled and with Calendar access denied or not requested.

The saved override is optional: older, missing or malformed values use System default. Valid choices use Foundation weekday numbers, Sunday=1 through Saturday=7. Changing layout preserves event enablement, chosen account-calendar IDs, world clocks and unrelated preferences. Month selection remains local, including its existing time-zone and today-following behavior. The dialog omits an empty calendar list and expands when there are calendars to choose; expansion stays on screen when the full window fits.

## World clock names

Settings → General → **World clock zones** accepts up to six comma-separated zones, with optional `Name=Zone` labels, then **Save clocks**. Example: `Build server=UTC, London office=Europe/London, Asia/Shanghai`. Existing zone-only preferences remain valid; unnamed clocks display their zone. Empty input deliberately removes all world clocks.

Each zone must be recognized by Foundation and appear only once. Names allow up to 40 characters and 128 UTF-8 bytes, excluding control characters, commas and equals signs. Input is capped at 1,024 UTF-8 bytes. A bad batch changes nothing. Unsaved drafts survive switching Settings tabs; unrelated edits preserve saved labels. Damaged stored labels fall back to the corresponding zone without dropping that clock. Only selected zones' labels are retained.

Names are local preferences and do not alter time-zone or daylight-saving rules. Date & Time renders them from the same snapshot timestamp and existing cached formatter/shared sampler; there is no new timer, request or account access. Configure the world-clock table's text format separately in **Settings → General → World clock format…**; see [clock formats](CLOCKS.md#world-clock-detail-table-format).

## Permission and privacy

macOS 14+ requires **Full Access** permission to read events; there is no read-only EventKit permission. TinyStats uses this grant only to read events. It has no save, delete, event-creation or reminder API path. The usage description explains the purpose. Denied access offers a link to Calendar privacy settings; restricted, write-only, not-yet-requested and unavailable access remain explicit states.

No event permission is requested on launch, on opening Date & Time or from a sampler tick. Only the explicit Allow action requests it. Tests inject a source and never grant permission to real accounts. Event titles/calendar names remain in memory; no event content is written to preferences, logs, diagnostics, history, benchmark records or an external service. Only the event opt-in, selected calendar identifiers and week-layout choice persist. Existing macOS account synchronization is managed by the OS, rather than a TinyStats network client.

## Collection and resource bounds

One lazily created EventKit store stays on a dedicated utility queue so Calendar database work cannot block system sampling or the UI. The main actor receives value snapshots, never EventKit objects. One operation can be in flight; rapid date/selection changes coalesce to the latest demand and stale completions are discarded. Date & Time skips the unused general process scan. No calendar timer is added.

The existing shared sampler deliveries drive at most one refresh every 60 seconds, plus an invalidation after a date/selection change or EventKit store-change notification. Notifications only set a locked flag, coalescing into the next existing tick. Queries cover one local calendar day using calendar arithmetic, including 23/25-hour DST days. The chooser reads calendar metadata without fetching event titles.

Retained metadata is limited to 64 calendars. Event enumeration stops after 2,048 examined candidates and retains at most 128 sorted rows, with explicit partial-result indicators. EventKit does not promise enumeration order, so a scan-limited result is not claimed to contain the earliest events in the entire store. The framework returns its calendar catalog as an array before TinyStats applies its retention limit; internal framework allocations are outside that cap. Event titles are limited to 160 characters and calendar/source names to 80. Notes, locations, attendees and event URLs are not read.

Leaving Date & Time, closing its UI, disabling events, pausing or sleeping clears the agenda immediately. When no calendar UI needs the store, it and its observer are released on the utility queue. An already-running synchronous EventKit call cannot be forcibly canceled; its completion is ignored after invalidation, and release follows it. The calendar chooser may retain calendar names while it is visible, even with events disabled, but requests no event range.

## Evidence and remaining validation

Deterministic fixtures cover permission/visibility gates, coalescing, stale-result rejection, suspension/cleanup, malformed-selection fail-closed decoding, bounded ordering, recurring occurrences, DST boundaries, midnight exclusion, leap-month navigation, time-zone changes and child/parent preference synchronization. Native and package evidence is recorded in validation; measured workload costs are recorded in [performance](PERFORMANCE.md).

Live authorized account reads, permission grant/revocation UI, account changes and representative hardware/lifecycle behavior still require validation. This implementation does not create/edit events, show reminders, open meeting links or provide weather.

API sources: Apple's [EventKit access model](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [full-access request](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)), [change notifications](https://developer.apple.com/documentation/eventkit/updating-with-notifications), and the SDK's EKEventStore.h enumeration documentation. This uses public EventKit APIs; no proprietary implementation was needed.
