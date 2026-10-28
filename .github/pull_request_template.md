## Change

Describe the concrete problem, resulting behavior and remaining limitations. Link a related issue if there is one.

## Validation

For source, tests, resources, packaging or validation changes:

- [ ] `scripts/verify-local.sh` passes on the final inputs.
- Host OS/build, architecture and toolchain:
- Source commit and manifest (`build/ci/source-manifest.json`):
- Swift/Python tests, format, strict warnings, universal app/unbundled-helper packaging, signatures, deployment and diagnostic results:
- Relevant regression/native UI/resource evidence and limits (sanitized):
- [ ] Final diff reviewed for correctness, unavailable data, privacy, bounded work/history and UI lifetime.

For documentation-only changes, record `git diff --check` and factual/link checks instead of rebuilding an unchanged app. Keep generated build logs/manifests locally; share only sanitized relevant evidence.

A local host pass and universal compilation do not establish native Intel or macOS 14/15 runtime coverage. See [Contributing](../CONTRIBUTING.md).
