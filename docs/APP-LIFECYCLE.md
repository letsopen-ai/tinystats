# Application lifecycle ownership

Issue #13 maps the composition root and extracts three small responsibilities without changing collection or window behavior. The governing rules are [AGENTS.md](../AGENTS.md), [Contributing](../CONTRIBUTING.md) and [Design](DESIGN.md).

| Responsibility before extraction | Owner after extraction | Boundary |
| --- | --- | --- |
| Preferences-domain selection, initial Weather session preparation, history path and checkpoint factory | `ApplicationStartup` | Returns settings and a lazy factory. Opening/restoring/writing the store still happens on MonitorWorker's serial queue. An isolated domain never falls back to the default profile's history. |
| Workspace sleep/wake and application power/time/locale registrations | `ApplicationLifecycleObservers` | Holds six center/token pairs and forwards events through the same main-actor Task hop. Start is idempotent; termination removes tokens from their original centers. It has no worker, timer, settings or windows. |
| Native status-item creation/replacement, rendering, sender identity, hit testing and menu-preview geometry | `StatusItemController` | Owns items/readout views, preserves reverse creation order and autosave identities, and consumes existing snapshots/history. It returns the sender's module/item; it does not open windows or request collection. |
| Startup ordering and worker construction/delivery wiring | `AppDelegate` | Rejects a duplicate instance and invalid cycle probe before creating items or the worker. Starts one worker, then Weather setup, observers and preview routing in the existing order. |
| Popover, persistent main window, Settings promotion and child editors | `AppDelegate` with existing controllers | Owns the shared DetailController and its transfer/detachment. `PopoverInteraction` continues to own visible-only dismissal monitors. |
| Pause/sleep state, remote-value invalidation and UI-to-worker demand | `AppDelegate` | Sets suspension state before invalidating remote snapshots; sends refreshed settings to the worker before refreshing Calendar demand. Selection alone does not grant hidden-window demand. |
| Collection, timer, baselines, bounded history and checkpoint I/O | `MonitorWorker` | Unchanged serial utility queue, one shared coalesced timer, bounded mailbox/history and sampler ownership. Pause/sleep reset baselines and sustained alerts. Resume/wake rearm only when both suspension flags are clear. |
| Quit decision and bounded checkpoint completion | `AppDelegate`, `HistoryQuitCoordinator`, `MonitorWorker` | Unchanged terminate-now/later decisions, once-only reply, two-second one-shot modal/common-run-loop deadline and worker checkpoint/stop ordering. |

The review sequence is deliberately small:

1. Move launch-only configuration and the lazy history-store factory, retaining isolated/default Weather behavior and history privacy guards. Regression fixtures cover saved On/Off, stale coordinates, lazy creation and excluded default-profile paths.
2. Move notification registrations, retaining notification names, centers, main-actor delivery and the order of each delegate transition. Regression fixtures post to private centers and cover single registration, mapping and removal without putting the Mac to sleep.
3. Move native status-item ownership and rendering, retaining AppDelegate's target/action and window routing. Existing menu rendering, popover interaction, Settings lifetime, main-window visibility and worker-demand regressions remain applicable.

AppDelegate remains the composition and window-routing owner intentionally: splitting Settings promotion, close callbacks and the shared detail controller into a separate window coordinator would introduce a second ordering-sensitive state owner. A later extraction should move those properties and transitions together, with native show/switch/promote/minimize/restore/close evidence, rather than scattering delegate extensions or adding a forwarding layer around MonitorWorker.

The retained routing contract is:

- The clicked status sender selects its own module. Clicking the current page closes the popover; another sender switches the same controller. Right-click retains the temporary native options menu.
- A visible popover or visible, nonminiaturized main window can demand the selected monitoring page. Settings removes monitoring demand; CPU/Memory/Disks alone request general process scans and Network alone requests its kernel stream. Calendar additionally requires the Time page, or its visible configuration window, and obeys suspension.
- Settings moves the controller to the main window before closing the popover. A delayed popover close cannot stop demand for a visible main window. Closing detaches hosted content; the deferred cleanup checks current presentation before releasing detail state.
- Preview close/cycle/report deadlines remain on existing sample deliveries. No view timer, queue, collector, network request, hardware write or change to unavailable readings is introduced.

The unresolved asynchronous History Quit assertion remains a separate issue. Neither its implementation nor its existing deadline/modal regression tests are changed here. A passing deadline fixture is not proof that the reported native assertion is fixed.

Source contribution readiness and signed distribution remain separate in Goal audit and [Distribution](DISTRIBUTION.md).
