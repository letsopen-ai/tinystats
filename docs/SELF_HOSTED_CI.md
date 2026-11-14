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

- PR and fork code runs only on GitHub-hosted `ubuntu-latest` runners. Native
  Swift tests remain local on the maintainer MacBook. Self-hosted jobs accept
  only successful push-to-main-triggered `workflow_run` releases, or
  `workflow_dispatch` on `main`, in `letsopen-ai/tinystats`.
- Keep the organization runner group private-only, or restrict public access to
  the selected workflow
  `letsopen-ai/tinystats/.github/workflows/production-release.yml@refs/heads/main`.
  Do not allow unrestricted public repository access. This production-only
  restriction also prevents the two manual diagnostic/smoke workflows from
  using the runner.
- Signing secrets belong in the `production` environment with a required
  reviewer. Keep their existing names; see [Distribution](DISTRIBUTION.md#automatic-production-releases).
- Require maintainer approval for all outside-contributor workflow runs,
  including first-time contributors. Review workflow changes before approval.
- Remove the unused repository-scoped runners `mac-mini-m4-release-tinystats`
  and `mac-mini-m4-tinystats` before making the repository public. No current
  workflow targets them, but an approved fork PR could add its own
  `runs-on: self-hosted` job and reach them. Labels and the policy test alone
  cannot prevent that: PRs control their own workflow and test files.
