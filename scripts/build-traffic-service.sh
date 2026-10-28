#!/bin/bash
# Development foundation only: builds an ad-hoc service that refuses privileged admission.
# Never bundles, installs, registers or launches a daemon. No signing identity/keychain access.
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p build
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/tinystats-traffic-build.XXXXXX")"
trap 'rm -r "$stage_dir"' EXIT
binary="$stage_dir/TinyStatsTrafficService"
if [[ "${1:-}" == --universal ]]; then
  for arch in arm64 x86_64; do
    swift build --configuration release --build-system native --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch" --product TinyStatsTrafficService
  done
  arm_bin="$(swift build --configuration release --build-system native --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --show-bin-path)"
  intel_bin="$(swift build --configuration release --build-system native --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --show-bin-path)"
  lipo -create "$arm_bin/TinyStatsTrafficService" "$intel_bin/TinyStatsTrafficService" -output "$binary"
elif [[ $# -eq 0 ]]; then
  swift build --configuration release --build-system native --product TinyStatsTrafficService
  bin_dir="$(swift build --configuration release --build-system native --show-bin-path)"
  cp "$bin_dir/TinyStatsTrafficService" "$binary"
else
  printf 'Usage: %s [--universal]\n' "$0" >&2
  exit 64
fi
xattr -cr "$binary"
codesign --force --options runtime --identifier com.niechen.tinystats.traffic-service --sign - "$binary"
codesign --verify --strict "$binary"
python3 scripts/check-traffic-service.py "$binary" --output build/traffic-service-dependencies.json
cp "$binary" build/TinyStatsTrafficService
printf 'Built unbundled development service: %s\n' "$PWD/build/TinyStatsTrafficService"
