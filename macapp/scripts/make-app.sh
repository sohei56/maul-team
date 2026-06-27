#!/usr/bin/env bash
# make-app.sh — build ScrumTeam and assemble a runnable .app bundle.
#
# Produces build/ScrumTeam.app with an Info.plist and an ad-hoc signature so it
# launches via `open` with a proper Dock icon and front window. This is for
# LOCAL use only — real distribution needs a Developer ID signature + notarization.
set -euo pipefail

CONFIG="${1:-debug}"   # debug | release
APP_NAME="ScrumTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/${APP_NAME}.app"

echo "==> swift build (-c $CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
[ -x "$BIN" ] || { echo "Error: binary not found at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>     <string>Scrum Team</string>
  <key>CFBundleIdentifier</key>      <string>com.claude-scrum-team.${APP_NAME}</string>
  <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "  (codesign skipped/failed — app still runs locally)"

echo "==> done: $APP"
echo "    open \"$APP\""
