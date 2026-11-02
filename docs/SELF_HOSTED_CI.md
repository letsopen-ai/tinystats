# Self-hosted Mac CI

The `Mac CI smoke` workflow is manually dispatched from `main` on the private
`niechen/tinystats` repository. Its runner labels are
`self-hosted`, `macOS`, `ARM64`, `mac-mini-m4`, `unsigned`, and `tinystats`.

The runner setup uses one repository-scoped registration per repository. Each
instance is configured to run as the standard local account `runner` using a system LaunchDaemon, so the
owner can keep using a separate desktop account. Runner processes do not run as
root. The initial workflow does not automatically execute pull requests.

## Run the smoke check

Open Actions → Mac CI smoke → Run workflow, select `main`, and dispatch.
Alternatively:

```sh
gh workflow run mac-ci-smoke.yml --repo niechen/tinystats --ref main
gh run list --repo niechen/tinystats --workflow mac-ci-smoke.yml --limit 5
```

The job has a 30-minute timeout, four compiler workers, read-only repository
permissions, and checkout credential persistence disabled. It checks its local
account and architecture, compiles the native executable, and runs the selected
pure logic test module. It requires a completed, nonempty Swift Testing summary;
a zero process exit alone is insufficient.

This is a bounded smoke check. It is not the complete local validation gate,
UI or device testing, a signed release, or minimum-OS/Intel runtime evidence.
No signing identity, notarization credential, or release publication is used.

## Operate the runner

The root-managed service is `com.niechen.ci.tinystats`. Its runner directory is
`/Users/runner/actions-runners/tinystats`, and service logs are under
`/Users/runner/Library/Logs/github-actions`. From an administrator account:

```sh
sudo launchctl print system/com.niechen.ci.tinystats
# Stop the service, for example before maintenance:
sudo launchctl bootout system/com.niechen.ci.tinystats
# Start it again after stopping:
sudo launchctl bootstrap system /Library/LaunchDaemons/com.niechen.ci.tinystats.plist
```

Check GitHub Settings → Actions → Runners for online status and inspect actual
job logs. The service uses `runsvc.sh` and the official runner's automatic
updates. Runner files, caches and logs persist; monitor disk use and review
logs before sharing. Never upload owner credentials or private desktop content.

## Isolation and availability limits

- The standard account is an account boundary, not a VM or a fresh job sandbox.
  Both repositories use the same account and can access each other's runner
  files. Execute only trusted workflows. Assess PR access separately before
  adding automatic triggers, including same-repository branch permissions.
- Keep the owner's login/keychain/signing material inaccessible to `runner`.
  Do not grant it sudo, log personal `gh` credentials into it, or add release
  secrets to these workflows. Verify its signing identity count is zero.
- The host shares CPU, RAM and disk with desktop use. Four compiler workers per
  smoke job bound compilation concurrency, but two repositories can run at once.
- System services do not provide an interactive desktop session. Tests needing
  windows, privacy permissions or simulator interaction require separate
  qualification. Locking the owner's screen is distinct from system sleep.
- System sleep interrupts job execution. After a restart, FileVault may require
  local unlock before normal service startup. Check service recovery,
  restart/unlock and sleep/wake behavior independently; configuration alone is
  not evidence that those checks passed.

Consult [GitHub runner scopes](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)
and [service configuration](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application).
