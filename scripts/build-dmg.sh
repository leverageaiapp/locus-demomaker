#!/usr/bin/env bash
# Build a Release .app and package it into a drag-to-install .dmg.
#
# Usage:  ./scripts/build-dmg.sh [output-path]
# Default output: build/dmg/Locus-DemoMaker.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="ScreenStudio"               # internal Xcode target name
SCHEME="ScreenStudio"
CONFIG="Release"
DISPLAY_NAME="Locus DemoMaker"
DMG_NAME="${1:-build/dmg/Locus-DemoMaker.dmg}"

BUILD_DIR="build/dmg"
DERIVED="$BUILD_DIR/derived"
STAGE="$BUILD_DIR/stage"

echo "→ Generating Xcode project…"
./setup.sh >/dev/null

echo "→ Building $CONFIG configuration…"
# We pipe through xcpretty when it's available for a tidy summary, but fall
# back to raw xcodebuild output otherwise. We never silence stderr — when the
# build fails on CI we need the actual compiler errors, not a silent exit.
if command -v xcpretty >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild \
    -project ScreenStudio.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    clean build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | xcpretty
else
  xcodebuild \
    -project ScreenStudio.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    clean build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
fi

APP_PATH="$DERIVED/Build/Products/$CONFIG/$TARGET.app"
[[ -d "$APP_PATH" ]] || { echo "✗ build product missing: $APP_PATH"; exit 1; }

echo "→ Staging DMG contents…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/$DISPLAY_NAME.app"
ln -s /Applications "$STAGE/Applications"

# The build above runs with signing disabled, which leaves a bundle whose
# linker-generated signature doesn't cover its resources — Gatekeeper rejects
# that outright on Apple Silicon. Re-sign the staged bundle so it carries a
# consistent signature: Developer ID when available, ad-hoc otherwise.
echo "→ Signing staged app…"
DIST_IDENTITY="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }'
)"
codesign --force --deep --sign "${DIST_IDENTITY:--}" \
  --options runtime \
  --entitlements Sources/ScreenStudio/ScreenStudio.entitlements \
  "$STAGE/$DISPLAY_NAME.app"
codesign --verify --strict "$STAGE/$DISPLAY_NAME.app"
echo "  signed with: ${DIST_IDENTITY:-ad-hoc}"

echo "→ Packaging DMG…"
mkdir -p "$(dirname "$DMG_NAME")"
rm -f "$DMG_NAME"
hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG_NAME" \
  >/dev/null

SIZE="$(du -h "$DMG_NAME" | cut -f1)"
echo "✓ $DMG_NAME ($SIZE)"
