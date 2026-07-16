#!/usr/bin/env bash
#
# MaulTeam for Mac
# Copyright (c) 2026 sohei56. All rights reserved.
#
# Source-available; NOT covered by this repository's MIT License.
# See macapp/LICENSE for terms.
#
# make-dmg.sh — package build/MaulTeam.app into a distributable .dmg.
#
# Zero external dependencies: uses hdiutil (always present on macOS), not
# create-dmg. Produces build/MaulTeam-<version>.dmg containing the app plus an
# /Applications symlink so the user can drag-install. Run make-app.sh first.
#
# Installer styling (Orca-style drag-to-Applications window): a UDRW image is
# mounted and Finder is scripted via osascript to set the window bounds, icon
# positions, and a generated dark background (scripts/dmg-background.swift),
# then the image is converted to compressed UDZO. Styling is best-effort: if
# Finder scripting fails (3 attempts) the script falls back to an unstyled but
# fully functional dmg so a cosmetic regression never blocks a release.
#   DMG_NO_STYLE=1      skip styling entirely
#   DMG_STYLE_STRICT=1  fail hard instead of falling back (layout development)
# First local run prompts "Terminal wants to control Finder" (TCC) — allow it.
#
# Signing: if DEVELOPER_ID_APP is set the .app is expected to be already signed
# by make-app.sh; this script additionally signs the .dmg itself when an
# identity is available (a notarization prerequisite). Unsigned otherwise.
set -euo pipefail

APP_NAME="MaulTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/${APP_NAME}.app"
SIGN_ID="${DEVELOPER_ID_APP:-}"

[ -d "$APP" ] || { echo "Error: $APP not found — run make-app.sh release first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="$ROOT/build/${APP_NAME}-${VERSION}.dmg"
VOLNAME="${APP_NAME} ${VERSION}"
# Temp RW image: must NOT match the MaulTeam-*.dmg glob that
# sign-and-notarize.sh (newest_dmg) and release.yml (checksums) select on.
RW="$ROOT/build/dmg-rw.tmp.dmg"

# Assemble a staging dir: the .app + a symlink to /Applications.
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

MOUNT_DEV=""
MOUNT_POINT=""

cleanup() {
  if [ -n "$MOUNT_DEV" ]; then
    hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Render the retina background into the staging dir (all dot-prefixed, so
# Finder hides it without SetFile -a V).
prepare_style_assets() {
  mkdir -p "$STAGE/.background"
  swift "$ROOT/scripts/dmg-background.swift" "$STAGE/.background" >/dev/null || return 1
  tiffutil -cathidpicheck "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 || return 1
  rm -f "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png"
  if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  fi
}

# Window bounds {200,120,860,540} = 660x420; icon positions are icon centers
# and must match the slot centers drawn by dmg-background.swift.
finder_layout() {
  osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 540}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "${APP_NAME}.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
}

detach_rw() {
  [ -n "$MOUNT_DEV" ] || return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if hdiutil detach "$MOUNT_DEV" >/dev/null 2>&1; then
      MOUNT_DEV=""
      return 0
    fi
    sleep 2
  done
  if hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1; then
    MOUNT_DEV=""
    return 0
  fi
  return 1
}

build_plain() {
  rm -f "$DMG"
  hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
}

build_styled() {
  prepare_style_assets || { echo "==> background generation failed" >&2; return 1; }

  local size_mb attach_out attach_line ok i
  size_mb=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
  rm -f "$RW"
  hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ -format UDRW -size "${size_mb}m" \
    -ov "$RW" >/dev/null || return 1

  attach_out="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")" || return 1
  attach_line="$(printf '%s\n' "$attach_out" | grep '/Volumes/' | head -1)"
  MOUNT_DEV="$(printf '%s\n' "$attach_line" | awk '{print $1}')"
  MOUNT_POINT="/Volumes/${attach_line#*/Volumes/}"
  [ -d "$MOUNT_POINT" ] || { detach_rw; return 1; }
  sleep 2  # let Finder register the freshly mounted volume

  ok=0
  for i in 1 2 3; do
    if finder_layout; then ok=1; break; fi
    echo "==> Finder layout attempt $i failed; retrying in 4s" >&2
    sleep 4
  done
  if [ "$ok" != 1 ]; then detach_rw; return 1; fi

  # Finder flushes .DS_Store asynchronously — wait for it before detaching.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MOUNT_POINT/.DS_Store" ] && break
    sleep 1
  done

  # Volume icon: best-effort, degrades to the generic icon without SetFile.
  if command -v SetFile >/dev/null 2>&1 && [ -f "$MOUNT_POINT/.VolumeIcon.icns" ]; then
    SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
  fi
  sync

  detach_rw || return 1
  rm -f "$DMG"
  # Block-level conversion preserves .DS_Store/.background/volume-icon attrs.
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null || return 1
  rm -f "$RW"
}

echo "==> building $DMG"
# Stale mounted MaulTeam volumes (e.g. a previously opened dmg) can make
# Finder scripting fail with -10006; warn so the fallback isn't a mystery.
if ls -d "/Volumes/${APP_NAME} "* >/dev/null 2>&1; then
  echo "WARNING: another ${APP_NAME} volume is mounted — eject it if styling fails" >&2
fi
if [ -n "${DMG_NO_STYLE:-}" ]; then
  echo "==> DMG_NO_STYLE set — building unstyled dmg"
  build_plain
elif build_styled; then
  echo "==> installer window styled (background + icon layout)"
else
  if [ -n "${DMG_STYLE_STRICT:-}" ]; then
    echo "Error: dmg styling failed and DMG_STYLE_STRICT is set" >&2
    exit 1
  fi
  echo "WARNING: dmg styling failed — shipping an unstyled but functional dmg" >&2
  build_plain
fi
rm -rf "$STAGE"
rm -f "$RW"

# Sign the DMG when a Developer ID identity is available (required before the
# DMG can be notarized/stapled).
if [ -n "$SIGN_ID" ]; then
  echo "==> codesign dmg ($SIGN_ID)"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
else
  echo "==> dmg unsigned (set DEVELOPER_ID_APP to sign — required for distribution)"
fi

echo "==> done: $DMG"
