#!/bin/bash
# Assembles build/Lggr.app from the SwiftPM executable product.
#
# Xcode is not required. SwiftPM produces a bare Mach-O executable, which macOS will happily run but
# will not treat as a real application: no bundle identifier, no menu bar ownership, no Info.plist
# usage strings, and no stable identity for the TCC database that records Accessibility consent.
# Wrapping the binary in a signed .app bundle fixes all four.
#
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIGURATION="${1:-release}"
APP_NAME="Lggr"
EXECUTABLE_NAME="LggrApp"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> Building $EXECUTABLE_NAME ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION" --product "$EXECUTABLE_NAME"

BINARY_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)/$EXECUTABLE_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "error: expected executable not found at $BINARY_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BINARY_PATH" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
    echo "    note: Resources/AppIcon.icns not present; run Scripts/make-icon.sh to generate it"
fi

plutil -lint "$CONTENTS/Info.plist" > /dev/null

echo "==> Signing (ad-hoc)"
# An ad-hoc signature is enough for local use and, critically, gives the bundle a stable code
# identity so macOS remembers the Accessibility permission across rebuilds instead of re-prompting.
# Distributing to another Mac would require a Developer ID signature and notarisation.
codesign --force --sign - \
    --entitlements "$ROOT/Resources/Lggr.entitlements" \
    --options runtime \
    --timestamp=none \
    "$APP_BUNDLE"

codesign --verify --verbose=1 "$APP_BUNDLE"

echo ""
echo "Built $APP_BUNDLE"
echo "  open $APP_BUNDLE"
