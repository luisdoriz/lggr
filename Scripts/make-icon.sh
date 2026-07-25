#!/bin/bash
# Generates Resources/AppIcon.icns from Scripts/IconGenerator.swift.
#
# The icon is drawn in code rather than checked in as a binary so it stays reviewable and editable.
# Re-run after changing IconGenerator.swift, then re-run Scripts/make-app.sh to pick it up.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

WORK_DIR="$(mktemp -d -t lggr-icon)"
trap 'rm -rf "$WORK_DIR"' EXIT

ICONSET="$WORK_DIR/AppIcon.iconset"

echo "==> Compiling the icon generator"
swiftc -O -target arm64-apple-macosx14.0 \
    -o "$WORK_DIR/icongen" \
    "$ROOT/Scripts/IconGenerator.swift"

echo "==> Rendering icon variants"
"$WORK_DIR/icongen" "$ICONSET"

echo "==> Packing AppIcon.icns"
iconutil --convert icns --output "$ROOT/Resources/AppIcon.icns" "$ICONSET"

echo "Wrote $ROOT/Resources/AppIcon.icns"
