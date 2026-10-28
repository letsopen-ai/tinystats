#!/bin/bash
# Regenerate committed brand artwork from scripts/create-icon.swift. Builds copy the
# committed Resources/TinyStats.icns, so rerun this after changing the artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf Resources/AppIcon.iconset
swift scripts/create-icon.swift Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/TinyStats.icns
swift scripts/create-icon.swift --svg docs/brand
swift scripts/create-icon.swift --brand docs/brand
printf 'Regenerated Resources/AppIcon.iconset, Resources/TinyStats.icns and docs/brand\n'
