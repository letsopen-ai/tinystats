# Experimental fan-control policy

This is **unreleased policy code**, not enabled fan control. `TinyStatsFanControl` is an isolated target, outside the app and traffic helper dependency graphs. It has no SMC transport, writer, IPC, timer, installer or persistent setting. The app reads fan RPM only. No fan setting has been changed by this work.

The competitive baseline is [iStat Menus 7 fans](https://bjango.com/help/istatmenus7/fans/): automatic control, temperature curves and temporary manual settings, with the system able to demand higher speeds. TinyStats targets that full behavior. The policy core is a prerequisite; it does not complete the feature.

## Implemented contract

- Automatic/default/stop produce a system-restoration decision. A future actuator must restore only the minimum-floor values owned by its current session, never rewrite another controller's mode or global fan state.
- At most eight unique fan rules and eight unique sensor keys per curve; two to eight finite, strictly temperature-ordered, nondecreasing curve points. Fractions run from zero (the verified minimum) to one (the verified maximum); piecewise-linear interpolation rounds RPM upward and stays within limits. Unsupported inputs fail closed.
- Manual settings are temporary per-session minimum RPM requests, bounded by verified hardware limits. Nothing persists or resumes across process restart by default. No zero-RPM or forced-target fallback is inferred from a key name.
- Curves use the hottest of **all explicitly selected** fresh temperature sources. Missing, duplicate, non-finite, future or stale selected samples restore system control; unrelated sensors never become substitutes. A bounded map indexes up to 64 selected keys from at most 128 supplied readings once per evaluation.
- The complete fan/sensor batch validates before output/history changes. Hardware inventory is bounded and unique, and a retained RPM that exceeds changed bounds cannot survive hysteresis. Desired increases apply immediately. Decreases wait until demand has remained below the previous output for five seconds; this does not require one exact candidate RPM to remain constant. Each fan has its own cooling clock, and reheating to the prior output resets it. Hysteresis applies within the current configuration; explicit reconfiguration starts a new session without retained cooling history.
- Inventory and selected-source samples must be no older than five seconds, measured from one shared monotonic, sleep-inclusive reference. Unknown/serious/critical thermal state restores system control. Native code must create these frames; IPC callers cannot assert hardware capability, temperatures or thermal state.
- Explicit configuration arms a device/session token. Only a separate keep-alive renews the ten-second client lease; evaluating a frame never does. Expiry cannot be revived with a late heartbeat. Device replacement and invalid/backward clocks latch a stopped session until explicit reconfiguration.

This target returns **decisions only**. A restoration decision does not prove that any hardware has been restored. A future service must execute verified, ownership-aware restoration and report failures independently of policy evaluation.

## Required before activation

1. Implement a separately reviewed native adapter that positively establishes a raise-only minimum-floor operation while the firmware/system retains authority to demand higher RPM. Readable minimum/target/mode keys and a successful write/readback do not alone prove this thermal behavior. The local unprivileged F0Mn metadata does not advertise the conventional public-write bit; root capability/semantics remain unproven. Never select a write protocol just from Intel/Apple Silicon or M-family names. Separate daemon research identifies multiple minimum and mode/target mechanisms; a floor-key-only adapter would leave modern coverage incomplete.
2. Keep the read-only collector unchanged. Do not add arbitrary SMC key/value, target/mode or diagnostic-unlock RPCs to the traffic service. Use a separate narrow fan-control boundary with signature-pinned callers, explicit opt-in, fixed typed operations and native validation.
3. Capture baseline/ownership receipts before any write. A reported failure may follow a partial firmware operation, so verify results and restore every possibly modified owned value. Bound retries, retain unresolved restoration state and report it; do not apply another boost while restoration/ownership is unresolved. Avoid sleep/retry loops. Detect competing controllers and changed devices without overwriting their settings.
4. Add a bounded one-shot lease watchdog and startup/shutdown/connection-loss recovery around the native controller. The pure core has no timer: a crashed/hung client cannot be handled merely by hoping another tick arrives. A blocked kernel operation can delay restoration; do not promise a hard deadline.
5. Validate genuine signed/root admission, automatic/manual/curve behavior, firmware demand overriding boosts, partial failures, competing control, app/helper crash/hang, sleep/wake/reboot, update/rollback, disable/removal and restoration on representative Intel/Apple Silicon hardware. No such positive write/recovery proof exists yet.
6. Integrate explicit native settings/menu controls and a production-rendered curve preview, retaining the shared sampler. Measure idle/active costs and prove no default writer/service activation before bundling or release.

This milestone does not close the full fan-control, distribution or resource gates.

## Policy-only measurement

One local M4 Release observation of 50,000 maximal-capacity synthetic evaluations averaged about 9.02 microseconds per call. This is in-process decision computation, with a fixed fresh virtual timestamp; it does not measure native sampling, IPC, writes, helper RSS/CPU/wakeups or restoration. Raw record and source hashes.

```sh
mkdir -p build
swiftc -O Sources/TinyStatsFanControl/FanControlPolicy.swift \
  scripts/benchmark-fan-policy.swift -o build/benchmark-fan-policy
build/benchmark-fan-policy
```

Compatibility record. No native fan actuation/recovery proof is claimed.
