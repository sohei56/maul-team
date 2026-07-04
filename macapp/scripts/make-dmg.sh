#!/usr/bin/env bash
# make-dmg.sh — package build/ScrumTeam.app into a distributable .dmg.
#
# Zero external dependencies: uses hdiutil (always present on macOS), not
# create-dmg. Produces build/ScrumTeam-<version>.dmg containing the app plus an
# /Applications symlink so the user can drag-install. Run make-app.sh first.
#
# Signing: if DEVELOPER_ID_APP is set the .app is expected to be already signed
# by make-app.sh; this script additionally signs the .dmg itself when an
# identity is available (a notarization prerequisite). Unsigned otherwise.
set -euo pipefail

APP_NAME="ScrumTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/${APP_NAME}.app"
SIGN_ID="${DEVELOPER_ID_APP:-}"

[ -d "$APP" ] || { echo "Error: $APP not found — run make-app.sh release first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="$ROOT/build/${APP_NAME}-${VERSION}.dmg"
VOLNAME="${APP_NAME} ${VERSION}"

# Assemble a staging dir: the .app + a symlink to /Applications.
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> building $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$STAGE"

# Sign the DMG when a Developer ID identity is available (required before the
# DMG can be notarized/stapled).
if [ -n "$SIGN_ID" ]; then
  echo "==> codesign dmg ($SIGN_ID)"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
else
  echo "==> dmg unsigned (set DEVELOPER_ID_APP to sign — required for distribution)"
fi

echo "==> done: $DMG"
