# Local validation and M4 release runner

The owner directs native tests for tinystats to run locally on the MacBook. The
M4 builds and signs release packages; it does not run the native test suite.
`Release source checks` (`mac-ci-smoke.yml`, retained path) runs only metadata
and receipt checks on Ubuntu. No GitHub-hosted macOS runner is used.

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
It runs as standard user `release-runner`, via system LaunchDaemon
`com.niechen.ci.letsopen-release`. The separate `letsopen-m4-unsigned` runner
uses standard user `runner` for other authorized repositories. The group permits
private repositories only. Old repository-scoped runners are excluded by the
`letsopen-org` label requirement.

No release-runner desktop or Apple ID/iCloud login is required for command-line
signing. GitHub Secrets materialize into private job-scoped files/keychains and
are removed on normal completion/cancellation. Releases share a lock across
repositories using that account. A standard account is not a VM: repositories
with release-runner access share its OS authority. Execute only trusted main
source. Forced termination can leave private staging; the next attempt refuses
to reuse it until inspected. Monitor disk space. FileVault startup unlock,
sleep and reboot recovery remain operational checks, not inferred guarantees.

See [signed distribution](DISTRIBUTION.md#automatic-production-releases) for verification and recovery.
