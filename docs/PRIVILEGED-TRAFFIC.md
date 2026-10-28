# Experimental modern traffic service

This is an **unreleased, unbundled foundation**, not an enabled feature of the app. The app still reports kernel TCP/UDP process accounting as partial. No service is installed, registered or started by TinyStats. An isolated experimental app client is implemented but not linked into the preview. App integration, explicit opt-in/registration/removal and positive signed-root validation are still required.

## Why this boundary exists

Apple's [XNU implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/ntstat.c) applies a privilege check to the newer providers even when legacy access is permitted. This finding does not prove that root alone will satisfy every OS policy; positive privileged execution is unverified.

The shared `TinyStatsTraffic` decoder has closed collection scopes. The default application subscribes only to kernel providers 2/4 and rejects modern frames. The experimental service selects **logical connection provider 9 only**, using the published 200-byte descriptor from macOS 14/current XNU. Its PID/name/unique-ID/timestamp fields have different offsets from kernel TCP/UDP. Live modern descriptors and byte counts have not been validated. Unknown sizes/providers fail closed; raw descriptors/UUIDs are not retained. Provider 10 subflows and kernel totals are never added to logical connection totals. Owned traffic must establish overlaps and coverage before a combined app total is designed.

## Security and data contract

- The standalone executable refuses normal launch unless effective UID is root and its own identifier/team signature validates, is not ad-hoc, has hardened runtime and lacks enabled debug-task access. Team identity comes from Security.framework's validated code signature, not client input or a plist.
- Native NSXPC listener and message requirements pin Apple's generic signing anchor, the same ten-character team and the exact TinyStats app identifier. They reject enabled get-task-allow. Before bundling, release validation must additionally verify the client's hardened runtime flags, packaging integrity and appropriate certificate/distribution policy. The requirement does not itself prove those flags or notarization.
- One accepted connection occupies the process. Only versioned snapshot and stop methods are exported. There is no generic command, path, provider, PID/UID selector, raw descriptor/socket transfer, fan write, installer or subprocess RPC. The caller's effective UID comes from NSXPC credentials and filters owners **before** top-eight selection. UID is part of accounting identity, including unattributed owners; source ownership changes invalidate the interval.
- Replies are at most 16 KiB/eight owners and have a fixed scope/version. Decoder/encoder checks reject unsupported versions, malformed identities, non-finite/negative rates, unbounded names/messages, invalid intervals, duplicate owner rows and numeric ready states without timestamps. No endpoints, network identifiers or credentials cross this contract.
- The serial utility queue owns the existing nonblocking reader. Admission coalesces requests before enqueueing; at most one snapshot job is pending. Cached samples limit native reads to at most twice per second even if a signed client calls faster. The isolated client uses shared sampler ticks, keeps one request in flight and rejects callbacks from replaced/disabled sessions.
- One active **one-shot** 30-second watchdog covers startup without an admitted peer, then transfers to a rescheduled session lease after admission. It also closes a client that never sends its first request. Rejected/absent peers cannot leave the service idle indefinitely. It is not a poll timer. Dispatch scheduling is not a hard real-time deadline, and a stuck kernel operation could delay queue progress. Stop/invalidation clears source state; closure causes the standalone service to exit. There is no independently repeating sampler.

## Development commands

```sh
swift test --build-system native
scripts/build-traffic-service.sh --universal
build/TinyStatsTrafficService --diagnose-policy
```

The build script always produces an ad-hoc development executable outside the app bundle; it never accesses a developer signing key, installs, registers, elevates or launches it. The policy diagnostic starts no listener. Normal unprivileged launch must refuse with exit 78. The ad-hoc build cannot pass the signed-root gate even if someone invokes it as root.

The existing default diagnostics never opt into modern providers. An owned anonymous XPC mock verifies the wire protocol; a wrong-identity native test verifies rejection before the export delegate. Neither is positive signed-root evidence.

## Gates before this can be enabled

1. Keep the isolated traffic targets and binary dependency audit passing. `TinyStatsTraffic` owns protocol/accounting and `CTinyStatsTraffic` owns only the POSIX boundary. The service no longer depends on the collectors/UI core; direct framework loads are limited to CoreFoundation, Foundation and Security. Standard Swift system libraries, including weak overlays, remain. This narrows linkage; it does not prove active helper memory/CPU costs.

2. Integrate the isolated app client only after the signed-root gate passes, with explicit opt-in/registration/unregistration via supported ServiceManagement APIs. Display approval/denial/unavailable states without automatic elevation or fallback to unrelated providers. The client implementation below does not complete that product flow or its live authentication proof.
3. Independently review the privilege boundary and verify both signed executables, client hardening, update/rollback behavior, installation paths and accepted certificate policy. A scoped independent source review of the client/shared IPC is complete; full signed/install/update privilege-boundary review remains open.
4. Validate a genuine developer-signed root session and native peer rejection/acceptance. The prior signing-key interaction stalled; it was cancelled without weakening security. Do not infer privileged operation from compilation, mocks or an EPERM probe.
5. Verify owned modern TCP/UDP/QUIC accounting, final/new sockets, multiple users, process/UID reuse, frame sizes and double-counting boundaries on supported OS families. Unknown or incomplete intervals must remain unavailable.
6. Measure active/idle/helper expiry and app costs, test client crash/hang/sleep/wake/update and remove all service state on opt-out. Establish full app attribution before claiming per-app parity.

This service does not provide fan control or complete network coverage yet.

## Isolation and native boundary correction (unreleased)

The service now shares only traffic models/protocol/accounting plus a standalone POSIX C target, not TinyStatsCore or its hardware/calendar/network-probe adapters. Core's public process-traffic model names remain source-compatible through aliases; the app uses a narrow kernel-session wrapper on the same serial sampler queue. The traffic fixtures move with their implementation.

The earlier C shim still rejected every provider except 2/4, despite the experimental Swift scope selecting 9. A separate fixed-provider-9 entry point now reaches the kernel without widening the kernel entry point or admitting subflow 10. An owned UNIX datagram fixture verifies actual native request bytes/guards; a separately enabled unprivileged native test receives kernel EPERM. Positive privileged accounting remains unverified.

That native path also revealed request-echo error frames. XNU may append the rejected request to its 24-byte error prefix. The decoder reads only the framed error prefix, never decodes/retains the opaque echo, and keeps numeric counter layouts strict. Unit fixtures cover echoed errors and the following outer frame; live modern denial and owned TCP/UDP traffic both pass locally.

Positive signed-root runtime and active service resource costs remain unverified.

## Isolated client (unreleased)

`TinyStatsTrafficIPC` owns only the shared wire/signing contract. `TinyStatsTrafficClient` depends on that narrow module and traffic models; neither target is in the main app dependency graph. Construction performs no signature lookup, Mach lookup or request. Both explicit enablement and service availability are required before a coalesced utility-queue setup job starts. That job validates the app's hardened signature and derives an exact same-team helper requirement before opening the fixed privileged Mach name. Authorization is rechecked around signature validation and before requesting a snapshot. There is no installer, registration, automatic elevation or configurable endpoint.

The native connection installs its code-signing requirement before resume and withholds every response unless kernel-supplied peer credentials report a positive PID and root EUID. Owned anonymous-XPC tests exercise rejection of a well-formed non-root reply. They do not establish successful root credentials or an installed, developer-signed handshake; those remain release gates.

A scoped independent source review found a delayed-setup cadence/backoff defect; fresh request/post-setup timestamps and regression fixtures correct it. No further concrete source findings remained. This is not a signed-runtime or full distribution security review.

The client has one mailbox job and one snapshot request in flight, at least one second between requests, a five-second request deadline and 60-second failure backoff, all driven by caller ticks. A completion gate prevents duplicate callback enqueueing. Wire replies are capped at 16 KiB/eight unique owners, and timestamps must belong to the current connection and be fresh. Disable, availability loss and backward-clock changes immediately withhold cached numbers. Revision/channel/request identity checks discard late callbacks; cached values expire after 15 seconds. Stop/deinitialization closes the channel; a best-effort stop RPC is followed by invalidation, with server invalidation/lease expiry providing cleanup when that RPC is not delivered. There is no independent repeating timer.

Fixtures cover bounded cadence/coalescing, timeout/backoff, stale/oversized/malformed/foreign-scope replies, duplicate replies/owner rows, session replacement, cancellation during delayed setup and deinitialization. The normal app remains kernel-only/partial. Real sleep/wake, signed-root acceptance, registration/removal, update/rollback, modern counters and active client/service costs still need validation before this can ship.

Those tests blocked on semaphores; they now suspend while awaiting lock-protected reply state with unchanged deadlines and authentication assertions. Local targeted and full strict-cooperative-pool runs pass. The initial timeout was not reproduced locally; executor contention remains an inference rather than a captured stack diagnosis. Apple's [Swift concurrency guidance](https://developer.apple.com/videos/play/wwdc2021/10254/) explains the forward-progress requirement behind this fixture change. Production code is unchanged by the test correction.
