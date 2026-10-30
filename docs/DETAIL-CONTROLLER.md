# Detail presentation and Settings ownership

Issue #12 separates two coherent responsibilities from `DetailController.swift` without changing settings or sampling behavior.

| Responsibility | Owner after extraction | Boundary |
| --- | --- | --- |
| Sidebar buttons, native shortcuts, selection drawing and layout | `DetailNavigationCoordinator` | Main actor; forwards module/Settings actions through weak controller captures. |
| Embedded General/Menu Bar root, replacement, hiding and width cap | `DetailNavigationCoordinator` | Holds the embedded view weakly; the host view hierarchy owns it. Does not create preferences or drafts. |
| Selected module, visible monitoring demand and callback order | `DetailController` | Settings still sends nil demand before embedding; returning to a module restores that module through existing callbacks. Hidden-window policy remains with the existing host. |
| Local Overview/CPU/GPU/Memory/Disks/Network/Power headlines, rows, meters and history series | `DetailReadingsBuilder` | Main-actor, input-only formatting of existing snapshots/history/settings. Returns transient presentation values; retains no sampler or history. |
| Native table cells, reuse/reload, selection, Copy value and accessibility | `DetailController` | Applies the builder result using the existing view hierarchy and table behavior. |
| Summary dashboards and responsive content layout | `DetailController` with existing `SummaryDashboardView` | Summary mode keeps its existing early return; it does not build hidden All readings. |
| Sensor search control, selected browser identity and bounded per-window timeline | `DetailController` | Owns lifetime/selection and applies the input-only builder; unchanged retention and sample rules. |
| Sensor Summary/All readings rows, search matching, focus rules and hottest chart projection | `SensorBrowserPresentation` | Main-actor, input-only builder; browser-only derived identities, no persisted selection or new timeline columns. |
| Weather controls, city selection, forecast formatting and daylight | `DetailController` with existing Weather views/helpers | Existing explicit permission action and opt-in boundaries remain at their current callbacks. |
| Calendar selection, agenda and clock formatting | `DetailController` with existing Calendar/Clock helpers | No event query or permission request is introduced by navigation. |
| General/Menu Bar preferences, persistence callbacks, previews and child editor lifetimes | Existing `PreferencesController` and child controllers | Settings keys and immediate controls are unchanged. Draft editors still own their Save/Cancel semantics. |
| Window/popover ownership and release | Existing `AppDelegate`, `MainWindow` and popover lifecycle | Closing still detaches the detail root/controller; the coordinator has no owning callback back to it. |

The shared timer, serial worker, collectors, permission providers and persisted settings model are outside this refactor. No collection demand, queue, timer, network destination, SMC write or history limit changes. The moved process formatting still shows at most seven rows and preserves its original ordering, units and missing-value handling. History series preserve nil gaps and valid zeroes.

Weather and Calendar retain their specialized interactive formatting in `DetailController`; issue #18 extracts Sensors formatting into `SensorBrowserPresentation`. Further separation can follow their individual lifetimes in later focused changes; it does not require changing this presentation/navigation boundary.

Regression coverage lives in `Tests/TinyStatsUITests/DetailPresentationTests.swift`: unavailable headlines/history gaps, idle meters and process bounds, native sidebar actions/shortcuts/Settings demand, deferred view loading, and controller/coordinator release with a retained native sidebar. Existing native suites cover table/component values, window resizing, Settings page release, editor Save/Cancel, Weather/Calendar permission boundaries and worker demand transitions.

## System dropdown presentation

`DetailController.isPopoverPresentation` selects the narrow material/platters layout. The default is the monitoring-window layout, including the System Overview grid, for window hosts and fixtures. `AppDelegate` sets the flag before loading a status-item detail, and clears it when promoting that same controller to a persistent window. The Open [module] in TinyStats action uses `onOpenInWindow`; it shares the existing window promotion/lifetime path without opening a Settings page.

Summary and Weather documents move into native scroll views only for dropdown presentation. Summary headlines use the lightweight `DetailReadingsBuilder.headline` formatter; they do not construct the hidden diagnostic rows. The All readings table, sensor search, date selection, History and Pause callbacks keep their existing ownership. The same native footer controls form a 34-point horizontal icon bar in every dropdown: leading History (where available), Open and All readings/Summary or Calendar; trailing Pause/Resume. The separator and footnote keep fixed spacing while scroll views receive the height reclaimed from stacked rows. `MenuActionRow` preserves titles and AX labels, uses simpler SF Symbol fallbacks and supplies neutral hover/pressed fills, native focus-ring masks and focused Space/Return activation. Native key-view traversal also retains the module’s search, calendar, grouping and Weather controls. Hiding/closing still uses the existing demand and popover dismissal rules. Appearance/system-colour redraws belong to shared presentation views and introduce no sampler activity.


In the persistent window, Overview's existing Pause/Resume and History buttons occupy its toolbar, with their callbacks unchanged; other pages keep their existing window action placement. Promoting a dropdown restores titled button presentation and widths; returning from Overview resets those frames and icons. The summary remains the same immediate-mode view and keeps its early return, bounded histories, hover inspection and reused accessibility children. Sidebar section headings display Advanced and Settings in secondary system text; module enum order, shortcuts and accessibility identities remain stable.


CPU/Memory/Network share one `ProcessGroupingControl`, owned by DetailController and reparented into the Summary process card header or the All readings heading’s trailing cell. The persisted Network key now applies to all three modules. The input-only readings builder consumes bounded worker app projections; it never reconstructs app totals from its seven process rows. A single detail-lifetime display cache supplies only drawn/realized bundle names/icons on the main actor; closing the controller releases the cache. See [Components](COMPONENTS.md#cpu-memory-and-network-process-grouping).
