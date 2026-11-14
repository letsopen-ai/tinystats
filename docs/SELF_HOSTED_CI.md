# Local validation and M4 release runner

The owner directs native tests for tinystats to run locally on the MacBook. The
M4 builds and signs release packages; it does not run the native test suite.
`Release source checks` (`mac-ci-smoke.yml`, retained path) runs workflow policy,
metadata and receipt checks on `ubuntu-latest` for pushes and PRs, including
forks. No GitHub-hosted macOS runner is used.

## Prepare local release validation

Commit all native source, tests, resources, packaging, workflows and scripts,
then run on the maintainer MacBook with its normal desktop session:

```sh
python3 scripts/local_release_validation.py record
git add docs/validation/local-release-validation.json
git commit -m 'ci(release): record local native validation'
```

The record command runs the complete `scripts/verify-local.sh` gate (Swift/Python tests, strict lint/warnings, universal packaging and local diagnostics).
Logs remain in ignored `build/local-release-validation`; review failures there.
Never fabricate or manually edit a passing receipt.

The committed receipt records the version, test recipe and SHA-256 of tracked
native input tree entries (including modes and Git object identities). A later
change to those inputs requires a new local run. A documentation-only or receipt
commit does not change that fingerprint. This is a maintainer test record with
source-integrity checks, not remote attestation. It proves only the recorded
host and selected recipe, not another OS, hardware or installed update.

An already-tagged version may pass the metadata check without a new receipt;
production independently skips it. For a new version, source checks and the M4
pre-credential gate require a matching committed receipt. PR/manual checks do
not authorize publication. Only successful main-push checks and a current-main
API authority check may start a production release.

## Organization runner

`letsopen-m4-release` is registered with `letsopen-ai`, using labels
`self-hosted`, `macOS`, `ARM64`, `mac-mini-m4`, `letsopen-org`, `release`, `tinystats`.
It belongs to the `default` organization runner group and runs as standard user
`release-runner`, via system LaunchDaemon `com.niechen.ci.letsopen-release`.
The same default group also contains `letsopen-m4-unsigned`, running as standard
user `runner` for other authorized repositories. The default group currently
allows private repositories only.
All three self-hosted workflows require these exact labels, including
`letsopen-org`; they do not select the legacy repository-scoped runners.

No release-runner desktop or Apple ID/iCloud login is required for command-line
signing. GitHub Secrets materialize into private job-scoped files/keychains and
are removed on normal completion/cancellation. Releases share a lock across
repositories using that account. A standard account is not a VM: repositories
with release-runner access share its OS authority. Execute only trusted main
source. Forced termination can leave private staging; the next attempt refuses
to reuse it until inspected. Monitor disk space. FileVault startup unlock,
sleep and reboot recovery remain operational checks, not inferred guarantees.

See [signed distribution](DISTRIBUTION.md#automatic-production-releases) for verification and recovery.

## Public repository safety

PR checks are designed to run only on GitHub-hosted `ubuntu-latest` runners;
no workflow in this repository sends PR code to self-hosted runners. Native
Swift tests remain local on the maintainer MacBook. The committed self-hosted
jobs are guarded for successful push-to-main-triggered `workflow_run` releases
or `workflow_dispatch` on `main` in `letsopen-ai/tinystats`.

A `pull_request` run uses the PR's own workflow files. Once a fork run is
approved, it can target any runner the repository can reach. Repository-side
guards, labels and the policy test cannot prevent this; runner reachability
and human approval are the actual controls. Fork PR workflows are disabled
while this repository is private. Once public, require approval for all
external contributors' workflow runs, including first-time contributors.
GitHub rejects that setting with HTTP 422 while the repository is private.

`letsopen-ai` is on GitHub Free, which offers only the default runner group.
Repository access and an "allow public repositories" option exist, but selected
workflow access is available only on GitHub Enterprise Cloud/Server. Keeping
the default group private-only after publication means this repository's
release job gets no runner. Maintainers must choose one of these options:

- **A (recommended):** run signing and releases from a separate private
  repository, such as `letsopen-ai/tinystats-release`, that checks out the public
  repository at the verified `main` SHA. Keep the default group private-only
  and signing secrets in the private release repository. This requires moving
  the release flow; the current public-repository job cannot use that group.
- **B:** allow public repositories on the default group. Restrict the group's
  repository access to selected repositories (`tinystats` only) if the UI offers
  it; this also removes access for other repositories currently using the group,
  so coordinate that change. Free cannot limit access to the release workflow.
  Accept that any approved fork run could reach both `letsopen-m4-release` and
  `letsopen-m4-unsigned`, regardless of the committed runner labels. Never approve
  fork runs that touch `.github/`. If one is approved by mistake, treat the
  runner host as compromised: a persistent runner can be altered for later
  signing jobs even without receiving signing secrets in the fork run.
  Consider ephemeral or just-in-time (JIT) runners.

Remove the unused repository-scoped runners `mac-mini-m4-release-tinystats`
and `mac-mini-m4-tinystats` before publication. No current workflow targets
them, but an approved fork PR could add a job that reaches them independently
of the organization group's policy.

### Production secret migration

For option B, use this order. GitHub Free does not support environment secrets
or required reviewers for this private repository (the reviewer API rejects the
request for its billing plan); both become available once it is public. Option A
keeps signing secrets in the private release repository at repository level;
an environment reviewer gate there requires a paid plan.

1. While private, keep the five signing secrets at repository level:
   `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`,
   `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`.
2. After publication, create all five in the `production` environment with the
   same names. Environment values take precedence over repository values.
3. Add a required reviewer and keep deployment branches limited to `main`.
4. Run a release and verify it uses the environment secrets and approval gate.
5. Then delete the repository-level copies. Until deletion, any main-branch job
   without `environment:` could read those copies and bypass the reviewer gate.

Each release then pauses for approval. See
[Distribution](DISTRIBUTION.md#automatic-production-releases) for release verification.

### Before making the repository public

- [ ] Plan to set Settings → Actions → General → "Require approval for all
  external contributors" immediately after publication; it cannot be set while
  private, when fork PR workflows are disabled.
- [ ] Remove the two legacy repository-scoped runners named above.
- [ ] Decide and prepare release option A or B, including the effect on both
  organization runners and other repositories using the default group.
- [ ] Plan the ordered secret migration above for after publication if using B;
  keep signing secrets in the private release repository if using A.
- [ ] Run `Release runner smoke` from `main` after the visibility/runner-access
  change (from the private release repository if using A).
