#!/bin/bash
# Local native validation backend. Assert the native runtime before collecting compatibility evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
expected_arch="${1:?expected native architecture}"
expected_major="${2:?expected macOS major version}"
package="${3:?native or universal}"
case "$package" in
  native|universal) ;;
  *) printf 'Unknown package mode: %s\n' "$package" >&2; exit 2 ;;
esac
mkdir -p build/ci
{
  git -C "${TINYSTATS_VALIDATION_SOURCE_ROOT:-.}" rev-parse HEAD
  uname -m
  sw_vers
  sysctl -n hw.logicalcpu
  xcodebuild -version
  swift --version
} | tee build/ci/platform.txt
actual_arch="$(uname -m)"
os_version="$(sw_vers -productVersion)"
test "$actual_arch" = "$expected_arch"
test "${os_version%%.*}" = "$expected_major"
translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || true)"
test "${translated:-0}" = 0
# Tests execute natively. A cross-compiled slice or a newer OS is not minimum-OS evidence.
export MACOSX_DEPLOYMENT_TARGET=14.0
python3 -m unittest discover -s scripts/tests -p 'test_*.py' 2>&1 | tee build/ci/benchmark-tests.txt
# Avoid starving clock-worker tests when UI fixtures compete for the main actor.
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  rm -f build/ci/test-evidence.txt
  : > build/ci/test-resources.txt
  touch build/ci/test-start
  scripts/hosted-test-evidence.sh sample &
  sampler=$!
fi
# Capture the pipeline status without letting diagnostics turn a failure into success.
set +e
swift test --build-system native --no-parallel -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror 2>&1 | tee build/ci/tests.txt
test_status=$?
# A stopped main run loop can make an async Swift test host exit 0 prematurely.
# Require the completed Swift Testing run, not just the process status.
if [[ "$test_status" -eq 0 ]]; then
  scripts/verify-swift-tests.sh build/ci/tests.txt
  test_status=$?
fi
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  if [[ "$test_status" -ne 0 ]]; then
    scripts/hosted-test-evidence.sh collect "$test_status" || true
  fi
fi
set -e
if [[ "$test_status" -ne 0 ]]; then exit "$test_status"; fi
if [[ "$package" == universal ]]; then
  scripts/build-app.sh --universal 2>&1 | tee build/ci/build.txt
else
  scripts/build-app.sh 2>&1 | tee build/ci/build.txt
fi
binary=build/TinyStats.app/Contents/MacOS/TinyStats
if [[ "$package" == universal ]]; then
  lipo "$binary" -verify_arch arm64
  lipo "$binary" -verify_arch x86_64
  expected_slices=2
else
  test "$(lipo -archs "$binary")" = "$expected_arch"
  expected_slices=1
fi
vtool -show-build "$binary" | tee build/ci/deployment.txt
test "$(grep -c 'minos 14.0' build/ci/deployment.txt)" -eq "$expected_slices"
codesign --verify --strict build/TinyStats.app
# Defaults keep external probes and Calendar account reads off.
"$binary" --diagnose 2>&1 | tee build/ci/diagnostics.txt

# The experimental service remains outside the app and is never installed or registered.
if [[ "$package" == universal ]]; then
  scripts/build-traffic-service.sh --universal 2>&1 | tee build/ci/traffic-service-build.txt
else
  scripts/build-traffic-service.sh 2>&1 | tee build/ci/traffic-service-build.txt
fi
cp build/traffic-service-dependencies.json build/ci/traffic-service-dependencies.json
service_binary=build/TinyStatsTrafficService
if [[ "$package" == universal ]]; then
  lipo "$service_binary" -verify_arch arm64
  lipo "$service_binary" -verify_arch x86_64
else
  test "$(lipo -archs "$service_binary")" = "$expected_arch"
fi
vtool -show-build "$service_binary" | tee build/ci/traffic-service-deployment.txt
test "$(grep -c 'minos 14.0' build/ci/traffic-service-deployment.txt)" -eq "$expected_slices"
codesign --verify --strict "$service_binary"
test ! -e build/TinyStats.app/Contents/Library/HelperTools/TinyStatsTrafficService
test ! -e build/TinyStats.app/Contents/Library/LaunchDaemons
test "$(id -u)" != 0
"$service_binary" --diagnose-policy | tee build/ci/traffic-service-policy.txt
set +e
"$service_binary" > build/ci/traffic-service-refusal.txt 2>&1
service_status=$?
set -e
test "$service_status" -eq 78
