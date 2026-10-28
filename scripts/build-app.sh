#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
if [[ "${1:-}" == "--universal" ]]; then
  for arch in arm64 x86_64; do
    swift build --product TinyStats --configuration release --build-system native --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
  done
  mkdir -p build
  arm_bin="$(swift build --configuration release --build-system native --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --show-bin-path)"
  intel_bin="$(swift build --configuration release --build-system native --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --show-bin-path)"
  lipo -create "$arm_bin/TinyStats" "$intel_bin/TinyStats" -output build/TinyStats
  binary=build/TinyStats
else
  swift build --product TinyStats --configuration release --build-system native
  bin_dir="$(swift build --configuration release --build-system native --show-bin-path)"
  binary="$bin_dir/TinyStats"
fi
# Check production source text and linked Release output (all universal slices)
# before signing/packaging. verify-local.sh reaches this through ci-macos.sh.
# The separate traffic-service binary has no UI and is intentionally not scanned.
python3 scripts/check-release-chrome.py --sources Sources "$binary"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/tinystats-build.XXXXXX")"
trap 'rm -r "$stage_dir"' EXIT
app="$stage_dir/TinyStats.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/TinyStats"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Committed artwork keeps builds deterministic; regenerate with scripts/generate-brand.sh.
cp Resources/TinyStats.icns "$app/Contents/Resources/TinyStats.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
xattr -cr "$app"
if [[ -n "${TINYSTATS_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$TINYSTATS_SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
ditto -c -k --norsrc --noextattr --keepParent "$app" build/TinyStats.zip
# Sign/package outside synced folders, then expose a local working copy.
ditto --norsrc --noextattr "$app" build/TinyStats.app
xattr -cr build/TinyStats.app
printf 'Built %s\n' "$PWD/build/TinyStats.app"
