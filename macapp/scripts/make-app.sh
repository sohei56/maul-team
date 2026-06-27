#!/usr/bin/env bash
# make-app.sh — build ScrumTeam and assemble a runnable .app bundle.
#
# Produces build/ScrumTeam.app with an Info.plist, an app icon, and an ad-hoc
# signature so it launches via `open` with a proper Dock icon and front window.
# This is for LOCAL use only — real distribution needs a Developer ID signature
# + notarization.
set -euo pipefail

CONFIG="${1:-debug}"   # debug | release
APP_NAME="ScrumTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/${APP_NAME}.app"
ICON_SRC="$ROOT/../images/macos_icon.png"

echo "==> swift build (-c $CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
[ -x "$BIN" ] || { echo "Error: binary not found at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Generate the app icon (.icns) from images/macos_icon.png if present.
ICON_PLIST=""
if [ -f "$ICON_SRC" ]; then
  echo "==> generating app icon from $ICON_SRC"
  ICONSET="$ROOT/build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
  ICON_PLIST='  <key>CFBundleIconFile</key>        <string>AppIcon</string>
'
else
  echo "==> no icon source at $ICON_SRC — skipping icon"
fi

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
${ICON_PLIST}  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
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
