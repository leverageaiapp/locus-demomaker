#!/usr/bin/env bash
# Generate the Xcode project. If an Apple Development cert is in the keychain,
# configure the project for stable signing so macOS TCC remembers Screen
# Recording / Accessibility grants across rebuilds.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  # security output: `1) HASH "Apple Development: Name (TEAMID10)"`
  DEVELOPMENT_TEAM="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'[()]' '/Apple Development/ { print $3; exit }'
  )"
fi

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  echo "✓ Found Apple Development cert for team $DEVELOPMENT_TEAM."
  echo "  Configuring project for stable signing (TCC permissions will persist)."
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="Apple Development" \
    xcodegen generate >/dev/null
  echo
  echo "  Next step: open ScreenStudio.xcodeproj in Xcode and ⌘R the first time."
  echo "  Xcode will auto-provision the Mac Development cert for this team."
  echo "  After that first run, every subsequent rebuild keeps TCC permissions."
else
  echo "ℹ️  No Apple Development cert in the keychain."
  echo "  Using ad-hoc signing — TCC will re-prompt on every rebuild."
  DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" xcodegen generate >/dev/null
  echo
  echo "  To fix permanently:"
  echo "    1. Xcode → Settings → Apple Accounts → sign in"
  echo "    2. Re-run this script"
fi

echo "✓ Project ready: ScreenStudio.xcodeproj"
