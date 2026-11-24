# Local validation and hosted release CI

`Release source checks` (`mac-ci-smoke.yml`) runs workflow policy tests on
Ubuntu and the full `scripts/verify-local.sh` gate on secret-free, public
GitHub-hosted macOS for pushes and pull requests. Both jobs must succeed for the
workflow to succeed. Actions logs and the job summary identify the run and
checked-out SHA; a PR run tests GitHub's checkout of its merge ref. Review the
workflow itself before trusting results from an untrusted PR.

The gate includes Python and Swift tests, the completed Swift test-run check,
strict format and compiler warnings, universal app and unbundled traffic-service
builds, architecture, deployment target and signature checks, CLI diagnostics,
and helper policy and refusal checks. Swift tests run without parallel test execution
to avoid starving the clock-worker cases under fixture load; no cases or time
limits are skipped. Python 3.11 is selected explicitly.

Maintainers may still run `scripts/verify-local.sh` locally. The historical
`docs/validation/local-release-validation.json` is a maintainer-recorded result,
not a remote attestation; a fresh receipt is not required for future releases.
A hosted pass covers its own Apple Silicon host and OS only. It is not native
macOS 14/15 or Intel runtime evidence, hardware qualification, or the interactive
`scripts/benchmark-app.py` measurement, which is not part of the recorded recipe.

## Hosted production flow

A successful same-repository main-push `workflow_run` from
`letsopen-ai/tinystats` can start `Production release` in the `production`
environment. Job-level concurrency serializes releases without cancellation.
The job checks out the exact successful SHA with full history and no persisted
credentials and verifies eligibility against GitHub's current main and run
metadata. For an unpublished version it verifies the pinned toolchain and runs
`verify-local.sh` again on that exact checkout before the signing step references
any secrets. Both the source workflow and this independent pre-sign gate must
succeed. Already-published versions are checked and skipped. PR and manual
source checks cannot authorize publication. The request and source checks run
again before signing and publication.

The runner is the standard arm64 `xcode-27` image: a 3-core M1 with 7 GB RAM and
14 GB SSD. `DEVELOPER_DIR` pins `/Applications/Xcode_27.1.app/Contents/Developer`;
the toolchain step requires Xcode 27.1 build 27A9275. It downloads the Metal
component if absent, then validates and selects its search path and identifier,
before any signing secrets are materialized. Production has a 180-minute job
timeout, a 20-minute toolchain step limit, a 900-second Metal download limit and
a 9,000-second release subprocess limit.
The temporary keychain unlock timeout is 10,800 seconds. No larger or xlarge
runner is allowed.

The exact Xcode build check (27A9275) intentionally stops the release if GitHub ships a different 27.1 build; run `Hosted release toolchain smoke` first.

The entry point requires non-root GitHub-hosted Actions execution and an owned,
real `$RUNNER_TEMP`. It restricts that directory to mode 0700 and exclusively
creates `$RUNNER_TEMP/tinystats-signing` (0700), refusing any existing path.
The Developer ID `.p12` and App Store Connect `AuthKey.p8` are mode 0600.
A temporary `release-signing.keychain-db` there uses a fresh random password.
The job imports the certificate, sets the partition list, adds the keychain to
the user search list, and verifies the identity SHA-1 and certificate subject OU
against `MACOS_CERTIFICATE_FINGERPRINT` and `APPLE_TEAM_ID` before signing.

`notarytool store-credentials` creates `tinystats-ci` in that temporary keychain
from the App Store Connect API key, key ID and issuer ID. There is no dependency
on a saved profile or login keychain. Raw signing secrets are removed from child
process environments. Python context-manager `finally` blocks detach/delete the
keychain and remove both credential files and staging. An independent
`Clean up signing material` step with `if: always()` repeats cleanup using the
same deterministic path; the ephemeral VM is discarded after the job.

`scripts/release_signed.py --actions-direct` retains the universal build,
notarization, stapling, signature/team/Gatekeeper checks and verified draft
publication. Assets remain `TinyStats-<version>-macOS-universal.zip`, `release.json`
and `SHA256SUMS.txt`. See [Distribution](DISTRIBUTION.md#automatic-production-releases).

`Hosted release toolchain smoke` (`hosted-release-smoke.yml`) is a secret-free,
main-only manual check of arm64, Xcode, Metal, Swift and request-guard fixtures.
It has read-only contents permission and no environment. The former self-hosted release runner
crash-report workflow has been removed.

## Public repository safety

All hosted macOS jobs require `github.event.repository.private == false`, so they
skip private repositories without allocating paid macOS minutes. Standard hosted runners are free and
unlimited for public repositories. A private repository would bill about $0.062
per minute for standard macOS, roughly $1–2 per release; the public-only guard
prevents that cost. Larger runners remain paid even for public repositories.

Require approval for all outside contributors' fork workflow
runs, including first-time contributors. Approved fork runs use the PR's own
workflow files, so review them carefully. Keep organization runner groups
private-only so this public repository cannot reach persistent runners. Untrusted PR
code must not receive signing secrets, and `pull_request_target` is forbidden.

### Production secrets and approval

Keep these five names unchanged:

- `MACOS_CERTIFICATE_P12_BASE64` and `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`

After publication, create all five in the `production` environment, set
`APPLE_TEAM_ID` and `MACOS_CERTIFICATE_FINGERPRINT` variables, restrict deployment
branches to `main`, and add required reviewers. Environment secrets take
precedence over repository copies of the same name. After verifying a hosted
release uses the environment and approval gate, delete repository-level copies;
otherwise another main-branch workflow could bypass reviewer approval.
Delete `APPLE_DISTRIBUTION_*` secrets if nothing else uses them; Developer ID
releases do not need them. Repository settings and secrets remain maintainer-managed.

### Before making the repository public

- [ ] Prepare the five production secrets and identity variables for migration;
  GitHub Free exposes environment secrets/reviewers once this repository is public.
- [ ] Keep org runner groups private-only; remove unused repository-scoped runner
  registrations so fork workflows cannot reach them after publication.
- [ ] Go public, then enable approval for all external contributors' workflow runs.
- [ ] Configure production secrets, required reviewers and the `main` branch policy.
- [ ] Merge this migration only after publication.
- [ ] Run `Hosted release toolchain smoke` from `main`, then watch the first new
  version's hosted release and independently verify downloaded assets.
- [ ] Validate the Xcode path, Metal download, notarization from hosted IPs,
  build/runtime on the 3-core M1, and universal build within 14 GB disk.
- [ ] After that release succeeds, retire the previous self-hosted release
  runners and their host services,
  coordinating with any other repositories. Keep them until then as a rollback
  path; no workflow here references them. Remove redundant signing secrets after
  checking other users.
