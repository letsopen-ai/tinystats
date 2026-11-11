# Compatibility

TinyStats targets **macOS 14 or newer**. Apple Silicon is the primary platform; the universal build also contains an Intel (`x86_64`) slice.

## What has been tested

- **Current source:** the full local check (`scripts/verify-local.sh`) runs on Apple Silicon (M4) with a recent macOS release. That covers the native Swift/XCTest and Python suites, strict warnings, universal app and traffic-service packaging, deployment-target and signature checks, and the Release `--diagnose` run on that host.
- **Earlier versions (0.10–0.12):** the test suite and Release diagnostics also ran natively on macOS 14 (arm64), macOS 15 (arm64) and macOS 15 (Intel). Those results have not been repeated for the current source.

A universal build compiled on one host, with a macOS 14.0 deployment target, shows that both slices build. It does **not** prove that the app runs correctly on macOS 14/15 or on Intel hardware. Reports from other Macs are very welcome; see [hardware diagnostics](../CONTRIBUTING.md#hardware-diagnostics).

## Hardware coverage

Hardware APIs vary by model and macOS version. TinyStats never assumes that an SMC key, GPU counter, battery field or frequency/power channel exists: a reading that is missing is shown as unavailable, not as zero. Known coverage limits:

- CPU/GPU active frequencies and model-power readings have been validated on Apple M4 only.
- SMART data has been validated on an internal Apple NVMe SSD only; ATA and external bridge enclosures are untested.
- Physical Intel sensors/GPU, multiple Apple Silicon generations, laptop battery/charging behavior and fan-equipped models need more coverage.
- Per-GPU-core activity is not available.

## Running the checks on another host

Building current source requires a Swift 6 toolchain whose macOS SDK declares the macOS 26 Liquid Glass types (Xcode 26 or newer is what we build with). Older toolchains such as Xcode 16 cannot compile this tree, even though the app's deployment target remains macOS 14.

Run the checks on the actual host you want to test, for example:

```sh
scripts/verify-local.sh                       # host architecture and OS, universal package
scripts/ci-macos.sh x86_64 15 native          # Intel Mac on macOS 15
```

`scripts/ci-macos.sh` fails if the actual architecture or macOS major version differs from the arguments, or if it is running under Rosetta. Logs go to `build/ci`. Use a clean checkout and note the commit when sharing results.

Passing these checks on a host does not cover physical sensors, interactive permissions, sleep/wake, external storage, VPN/hot-plug transitions or menu bar layout on notched displays; those still need manual checks.
