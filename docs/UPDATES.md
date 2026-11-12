# Updates

TinyStats 0.37.5 (77) adds a native updater with no third-party runtime dependency.
It consumes the existing public assets of [letsopen-ai/tinystats Releases](https://github.com/letsopen-ai/tinystats/releases).
**All releases before 0.37.5 have no updater. Install the first updater-enabled signed release manually.**

## Behavior and controls

Signed releases check once per 24 hours by default and prepare verified updates in
the background by default. Defaults favor timely fixes without interrupting normal
monitoring. The welcome tour and General settings disclose GitHub's role; both
preferences can be disabled in **Settings › General › Updates**. Saved Off choices
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
   tree, reject escaping symlinks and unsupported entries, and check bounded size.
3. Security.framework validates all architectures, strict resource sealing and
   nested code against this pinned Developer ID requirement:

   ```text
   identifier "com.niechen.tinystats" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "CVQJTDR4LG"
   ```

   The signing Team ID must also equal the running app's team. The `notarized`
   code requirement must pass, followed by `/usr/sbin/spctl --assess --type execute`.
   Bundle ID, short version and build in Info.plist must exactly match the release
   manifest. Apple trust/Gatekeeper policy can perform its own system checks.
4. Re-verify before launching a private copied executable helper via fixed argv
   (no interpolated shell commands). The helper creates a separate session and
   waits at most 120 seconds for TinyStats' PID to exit. The app uses its normal
   termination path, including the existing bounded history checkpoint completion.
5. After waiting, the helper checks the original bundle's inode, signature/team,
   writable location and the staged bundle again immediately before installation.
   Same-volume rename moves the original to a staging backup and the staged app
   to the exact original path. A move failure restores the old bundle. On an explicit restart, helper failure
   attempts to reopen the untouched or restored signed app and records the error
   in the local unified log. A relaunch error after successful installation is
   logged without rolling back or deleting the new app, which may already be running.
   Successful explicit restart uses `/usr/bin/open` on that path. Normal quit does
   not relaunch. The backup is removed only after success. Quarantine and Gatekeeper
   are never bypassed or disabled.

Failures remove candidate staging. An interrupted installation or failed rollback
retains the backup for recovery, refuses further preparation and requires manual
inspection. Preparing another candidate removes earlier unused candidates, bounding
retained update storage. Do not delete `Previous.app` until the installation has
been inspected. This is a two-rename transaction with rollback, not a crash-proof
filesystem exchange: a power loss between renames can require manual restoration.

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
