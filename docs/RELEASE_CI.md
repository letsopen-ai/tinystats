# Local validation and hosted release CI

`Release source checks` (`mac-ci-smoke.yml`, retained path) checks workflow policy,
metadata and local validation receipts on `ubuntu-latest` for pushes and PRs.
Native tests remain local on the maintainer Mac. All repository workflows use
standard GitHub-hosted runners; no self-hosted runner is needed.

## Prepare local release validation

Commit native source, tests, resources, packaging, workflows and scripts, then
run on the maintainer Mac:

```sh
python3 scripts/local_release_validation.py record
git add docs/validation/local-release-validation.json
git commit -m 'ci(release): record local native validation'
```

The record command runs the complete `scripts/verify-local.sh` gate. Logs stay
in ignored `build/local-release-validation`. Never fabricate or manually edit a
passing receipt. The receipt binds the version and recipe to tracked native
input tree entries, including workflows and scripts. Changed inputs require a
new local run. Documentation-only and receipt commits do not change that
fingerprint. This proves the recorded host and recipe, not other hardware or OS
runtime support.

An already-tagged version may pass source metadata checks without a new receipt;
production independently verifies its published assets and skips it. A new
version needs a matching committed receipt before signing credentials are loaded.
PR/manual source checks never authorize publication.

## Hosted production flow

A successful main-push `workflow_run` from `letsopen-ai/tinystats` can start
`Production release` in the `production` environment. Its job-level concurrency
serializes releases without cancellation. The job checks out the exact successful
SHA with full history and no persisted credentials, verifies eligibility against
GitHub's current main and run metadata, and checks the local validation receipt.
The same request/source checks run again before signing and publication.

The runner is the standard arm64 `xcode-27` image: a 3-core M1 with 7 GB RAM and
14 GB SSD. `DEVELOPER_DIR` pins `/Applications/Xcode_27.1.app/Contents/Developer`;
the toolchain step requires Xcode 27.1 build 27A9275. It downloads the Metal
component if absent, then validates and selects its search path and identifier,
before any signing secrets are materialized. Production has a 120-minute timeout;
no larger or xlarge runner is allowed.

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
It has read-only contents permission and no environment. The former Mac mini
crash-report workflow has been removed.

## Public repository safety

Merge this migration only after the repository is public. Both macOS jobs also
require `github.event.repository.private == false`, so merging early skips them
without allocating paid macOS minutes. Standard hosted runners are free and
unlimited for public repositories. A private repository would bill about $0.062
per minute for standard macOS, roughly $1–2 per release; the public-only guard
prevents that cost. Larger runners remain paid even for public repositories.

After publication, require approval for all outside contributors' fork workflow
runs, including first-time contributors. Approved fork runs use the PR's own
workflow files, so review them carefully. Keep organization runner groups
private-only so this public repository cannot reach persistent runners.

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
- [ ] Merge this migration (stacked on PR #35) only after publication.
- [ ] Run `Hosted release toolchain smoke` from `main`, then watch the first new
  version's hosted release and independently verify downloaded assets.
- [ ] Validate the Xcode path, Metal download, notarization from hosted IPs,
  build/runtime on the 3-core M1, and universal build within 14 GB disk.
- [ ] After that release succeeds, retire org runners `letsopen-m4-release` and
  `letsopen-m4-unsigned` and the Mac mini LaunchDaemons `com.niechen.ci.*`,
  coordinating with any other repositories. Keep them until then as a rollback
  path; no workflow here references them. Remove redundant signing secrets after
  checking other users.
