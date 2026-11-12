# Updates

TinyStats 0.37.5 (77) adds a native updater with no third-party runtime dependency.
It consumes the existing public assets of [letsopen-ai/tinystats Releases](https://github.com/letsopen-ai/tinystats/releases).
**All releases before 0.37.5 have no updater. Install the first updater-enabled signed release manually.**

## Behavior and controls

Signed releases check once per 24 hours by default and prepare verified updates in
the background by default. Defaults favor timely fixes without interrupting normal
monitoring. The welcome tour and General settings disclose GitHub's role; both
preferences can be disabled in **Settings › General › Software Update**. Saved Off choices
are preserved; malformed explicit preferences fail closed to Off.

The initial check waits a randomized three to seven minutes after launch and waits
until the welcome tour closes. Scheduling uses existing sample deliveries, including
an overdue check after wake, with no additional recurring timer. The last attempt
is persisted, including failures. Turning automatic checks off also disables the
automatic-download control. Manual **Check for Updates…** remains available.

Manual checks show native alerts for the latest version, a newer release, or an
error. Release Notes opens only this repository's HTTPS release pages. Background
failures remain silent and use the local unified log. A prepared update adds
**Restart to Update <version> (<build>)** to the app menu and Settings, plus a
small temporary download icon in the dropdown footer with restart help text.

**With automatic checking and downloading enabled, a prepared update also installs
on normal Quit, without reopening the app.** Turning either preference off prevents
that automatic quit installation. Explicit Restart to Update installs and reopens.
If you choose Quit while an explicit Restart to Update is already in flight,
its written plan still requests relaunch: a successful installation reopens
TinyStats. A helper-start failure still allows that Quit to finish.
Updates never change system power settings or install a privileged service.

Development, ad-hoc and test builds never start update requests. Eligibility requires
bundle identifier `com.niechen.tinystats`, a valid Developer ID signature from team
`CVQJTDR4LG`, notarization, no App Translocation, and a writable volume. Diagnostics, command-line
previews and isolated preference profiles also disable updating. Manual checks on
ineligible builds explain this and offer the release page. A parent directory that
is not writable, a bundle that is not writable or is owned by another user, a
symlinked installation, or a different volume from Caches offers
the release page instead of installing. No administrator prompt is used.

## Network and privacy

The unauthenticated request is:

```text
GET https://api.github.com/repos/letsopen-ai/tinystats/releases/latest
Accept: application/vnd.github+json
Accept-Language: en
User-Agent: TinyStats/<app version> (https://github.com/letsopen-ai/tinystats)
```

Release assets (`release.json`, `SHA256SUMS.txt` and ZIPs) and their redirected
asset-host requests use `Accept: application/octet-stream`; API-host requests
keep `Accept: application/vnd.github+json`. User-Agent and `Accept-Language: en`
remain the same across allowed redirects. Confirm these headers during the live
asset redirect-chain release check.

TinyStats sends no account, machine ID, hardware readings, history, location or other
personal identifier. Language is fixed to English rather than the user’s locale;
URLSession may add standard Accept-Encoding headers. GitHub sees the connection's public IP, like any HTTPS server.
The ephemeral URLSession disables cookies, credential storage and persistent URL
caches. Requests have a 30-second request timeout and 180-second total timeout,
with at most five redirects. JSON/checksum responses are capped at 1 MiB and ZIPs
at 64 MiB, both advertised and received bytes. A redirect must use HTTPS on port
443, with no credentials or fragment, to one of exactly:

- `api.github.com` — release metadata.
- `github.com` — release pages and asset download entry points.
- `objects.githubusercontent.com` — GitHub asset storage.
- `release-assets.githubusercontent.com` — GitHub asset delivery.

No wildcard is allowed. GitHub's [runner communication reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#accessible-domains-by-function)
documents the objects host; GitHub's [release-asset endpoint discussion](https://github.com/orgs/community/discussions/165767)
records both asset delivery hosts. Live redirects for this repository could not be
verified in the implementation sandbox (no direct network; configured proxy was
unreachable). Before release, independently inspect a current asset redirect chain.
A future GitHub host change fails closed until the allowlist is reviewed.

HTTP 429 responses and API-host 403 responses with a rate-limit header persist a
retry deadline using the later of Retry-After, X-RateLimit-Reset and a one-hour
fallback, capped at 24 hours. An asset-host 403 (for example, an expired signed
download URL) is an ordinary failure, not a rate-limit response. Manual checks also obey that deadline;
automatic attempts retain the daily minimum interval. HTTP-date Retry-After values
are supported. There is no rapid retry loop.

## Release asset contract

The existing signed release workflow already publishes this contract; no workflow
change is needed. A stable tag `vX.Y.Z` must have:

- `release.json`, with string `version`, decimal string `build`, lowercase 64-digit
  `sha256`, and `file` equal to `TinyStats-X.Y.Z-macOS-universal.zip`. The existing
  manifest's `sourceCommit`, `notarizationSubmission` and `verification` fields
  remain release provenance; the updater does not treat them as proof of trust.
- Exactly that ZIP asset, containing only the top-level `TinyStats.app` directory.
- `SHA256SUMS.txt` from the existing release pipeline. If present, its unique line
  for the ZIP must agree with the manifest. The updater also supports its absence.

Draft/prerelease flags, missing flags/fields, duplicate asset names, malformed tags,
incorrect asset URLs/names, mismatched versions, and oversized data fail closed.
The release version must be numerically greater than the running three-component
version **and** its integer build must be strictly greater than CFBundleVersion.
Equal versions/builds and downgrades are never offered.

## Verification and installation

1. Download into private staging under
   `~/Library/Caches/com.niechen.tinystats/Updates/<build>-<random>/` (0700;
   data files 0600). Compare ZIP SHA-256 with release.json and the optional sums.
2. Inspect the ZIP directory before `/usr/bin/ditto -x -k`: reject traversal,
   other top-level roots, duplicate/case-colliding paths, encrypted/ZIP64 archives,
   special files (including archived symlinks), alternate path metadata, local-header
   mismatches or unlisted/overlapping records, more than 20,000 entries, and more
   than 512 MiB expanded content. Current release bundles need no archived symlinks.
   After extraction, require exactly one directory `TinyStats.app`; inspect its
   tree, reject all symbolic links and unsupported entries, and check bounded size.
3. Security.framework validates all architectures, strict resource sealing and
   nested code against this pinned Developer ID requirement:

   ```text
   identifier "com.niechen.tinystats" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "CVQJTDR4LG"
   ```

   The signing Team ID must also equal the running app's team. The `notarized`
   code requirement must pass, followed by `/usr/sbin/spctl --assess --type execute`.
   Bundle ID, short version and build in Info.plist must exactly match the release
   manifest. Apple trust/Gatekeeper policy can perform its own system checks.
4. Re-verify before launching the original signed bundle's own executable via
   `posix_spawn`, fixed argv and `POSIX_SPAWN_SETSID` (no shell or bare executable
   copy). Its running image survives the subsequent bundle renames. Standard I/O
   points to `/dev/null`; a private inherited pipe is the only additional descriptor.
   The helper decodes and validates its plan inside the recovery path, then signals
   ready through that pipe. The app waits on a worker thread for at most 10 seconds.
   An early exit, malformed plan, missing signal or timeout stops and reaps the
   helper and discards the prepared update. An explicit restart failure shows the
   error and keeps TinyStats running unless an ordinary Quit is also pending.
   An ordinary Quit, logout or shutdown always continues through normal history
   checkpoint/termination even when update preparation fails; failure is logged
   without an alert. Only an explicit update restart requires a ready helper
   before initiating termination.
   The helper then waits at most 120 seconds for TinyStats' PID to exit.
5. After waiting, the helper checks the original bundle's inode, signature/team,
   writable location and the staged bundle again immediately before installation.
   It checks for another TinyStats process using that exact bundle path, excluding
   the helper and the parent whose exit was already confirmed. If one exists, it waits one second and retries once, then
   refuses replacement and follows the same failure/reopen path. This final check
   reduces the immediate-relaunch race; it does not provide a cross-instance lock.
   Same-volume rename moves the original to a staging backup and the staged app
   to the exact original path. A move failure restores the old bundle. On an
   explicit restart, helper failure after the parent exits (including plan decoding
   or validation failure) attempts to reopen the untouched or restored signed app.
   Ordinary Quit failures restore when needed and never reopen the app. Errors
   are recorded in the local unified log. A relaunch error after successful installation is
   logged without rolling back or deleting the new app, which may already be running.
   Successful explicit restart uses `/usr/bin/open` on that path. Normal quit does
   not relaunch after either success or failure. Backup removal after both renames is best-effort;
   failure to clean up does not turn a successful installation into a failure.
   Quarantine and Gatekeeper
   are never bypassed or disabled.

## Failures

Failures remove candidate staging. An interrupted installation or failed rollback
retains the backup for recovery. On launch, Settings shows **Update needs attention**
if a recovery backup cannot be safely discarded. Before preparing another update,
a stale recovery folder is removed only when the installed app passes the pinned
Developer ID and notarization requirements and its numeric version and build are
both at least as new as the authenticated backup. Otherwise the backup is preserved
and preparation fails closed with the same attention status. A cleanup error also
preserves that status. Preparing another candidate removes earlier unused candidates,
bounding retained update storage. Do not manually delete `Previous.app` until the
installation has been inspected. This is a two-rename transaction with rollback, not a crash-proof
filesystem exchange: a power loss between renames can require manual restoration.

If rollback itself fails, the backup stays at
`~/Library/Caches/com.niechen.tinystats/Updates/<build>-<random>/Previous.app`.
Recover it manually:

1. Quit every TinyStats instance. In Finder choose **Go › Go to Folder…** and enter
   `~/Library/Caches/com.niechen.tinystats/Updates/`. Open the recovery folder that
   contains `Previous.app` and `install.json`.
2. Open `install.json` as text and read the `original` URL. That is the exact
   installation path to restore; decode any URL-escaped spaces. Do not change the
   plan or run the helper manually. Preserve the whole recovery folder until done.
3. If an app already exists at the original path, move it aside without deleting
   or merging it. Move `Previous.app` into the original parent folder and rename it
   to **TinyStats.app**, matching the original path exactly. Do not merge bundles.
4. Open the restored app through Finder and confirm its version and normal behavior.
   Do not bypass any macOS security warning. If the backup is missing, corrupt or
   rejected, install a fresh signed ZIP from the official GitHub Releases page.
5. Only after confirming a working installation, remove the leftover recovery folder
   and any app you moved aside. An unresolved backup keeps the updater in the
   **Update needs attention** state instead of silently deleting the older app.

## Trust and remaining validation

release.json and SHA256SUMS come from the same GitHub release as the ZIP. They detect
corruption and inconsistent assets, but do not independently authenticate a release.
**The pinned Apple Developer ID signature is the authenticity anchor.** A GitHub
repository compromise alone cannot produce an acceptable app without that identity.
A compromise of the signing identity remains outside this updater's protection.

An owner may instead choose Sparkle with EdDSA for independently signed update
metadata, established installer behavior and delta updates. That option requires
a signing secret, additional dependency and release workflow changes; none are
introduced here.

Offline tests inject transports/security/processes and exercise real move/restore
operations only in temporary directories. Owned-window stills use synthetic
0.37.6 (78), no network and no-op installation actions. Alert and app-menu PNGs are owned content mirrors; native window
presentation was unavailable in the sandbox. They do not establish signed
end-to-end installation, Gatekeeper offline behavior, crash recovery, native macOS
14/15 or Intel runtime validation. Those remain release gates in
[Distribution](DISTRIBUTION.md).
