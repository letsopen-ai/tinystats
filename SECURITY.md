# Security policy

## Report a vulnerability privately

Please use [GitHub private vulnerability reporting](https://github.com/letsopen-ai/tinystats/security/advisories/new) to send a report to the repository's security advisory workflow. If that form is not available, email the maintainer at [git@cnie.xyz](mailto:git@cnie.xyz). Do not open a public issue with exploit details, personal data or credentials. The maintainer is [@niechen](https://github.com/niechen).

Include the affected version/commit, macOS version and architecture, reproduction steps, expected impact and a minimal sanitized example. Share only the information needed to reproduce the problem. Maintainers will coordinate investigation and disclosure through the advisory; there is no guaranteed response time or supported-version backport schedule yet. This is a preview project; please reproduce on the latest source when practical.

If GitHub does not offer the private reporting form, email [git@cnie.xyz](mailto:git@cnie.xyz) and ask for a private channel rather than filing a public vulnerability issue. The maintainer should also enable GitHub private vulnerability reporting on this repository so the advisory form works for everyone.

## Current boundaries

- Signed-release updates require pinned Developer ID team `CVQJTDR4LG`, notarization, Gatekeeper, SHA-256 agreement, HTTPS allowlisted hosts and a strictly newer version/build. See [Updates](docs/UPDATES.md) for trust boundaries and rollback limitations.

- SMC sensor collection is read-only. The app does not write fan settings.
- The privileged traffic helper is experimental, unbundled and unshipped. It must not install/register itself or run by default; signed-peer/root runtime validation and integration gates remain open. See [Privileged traffic](docs/PRIVILEGED-TRAFFIC.md).
- Fan control is experimental, unlinked decision logic, with no enabled hardware writer. Actuation, recovery and physical validation remain unshipped. See [Fan control](docs/FAN-CONTROL.md).
- Source-built apps are ad-hoc signed by default. Developer ID signing/notarization and broader hardware/runtime coverage remain [distribution gates](docs/DISTRIBUTION.md).

Network behavior and local history controls are described in the [README privacy section](README.md#privacy). Do not include saved locations, calendar events or unrelated diagnostics in a security report.
