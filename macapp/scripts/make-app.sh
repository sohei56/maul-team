#!/usr/bin/env bash
# make-app.sh — build ScrumTeam and assemble a runnable .app bundle.
#
# Produces build/ScrumTeam.app with an Info.plist and an app icon. Signing
# depends on the environment:
#
#   DEVELOPER_ID_APP unset  -> ad-hoc signature (LOCAL dev only, not
#                              distributable; Gatekeeper will quarantine it
#                              when copied to another machine).
#   DEVELOPER_ID_APP set    -> Developer ID signature + Hardened Runtime
#                              (--options runtime) + entitlements.plist, the
#                              prerequisite for notarization (see
#                              sign-and-notarize.sh). Set it to the identity
#                              string, e.g.
#                              "Developer ID Application: Your Name (TEAMID)".
#
# A `release` build is compiled universal2 (arm64 + x86_64) so the artifact
# runs on both Apple Silicon and Intel; `debug` stays single-arch for speed.
set -euo pipefail

CONFIG="${1:-debug}"   # debug | release
APP_NAME="ScrumTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/${APP_NAME}.app"
ICON_SRC="$ROOT/../images/macos_icon.png"
ENTITLEMENTS="$ROOT/entitlements.plist"
SIGN_ID="${DEVELOPER_ID_APP:-}"

# Version matches the GitHub release: the latest git tag (e.g. v1.4.3 -> 1.4.3).
VERSION="$(git -C "$ROOT/.." describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
[ -n "$VERSION" ] || VERSION="0.0.0"

# Release = universal2 (arm64 + x86_64) for distribution; debug = host arch.
#
# We build each arch SEPARATELY with the native build system and lipo them
# together, rather than `swift build --arch arm64 --arch x86_64`. Reason:
# passing multiple --arch routes SwiftPM to the "swiftbuild" backend, which
# tries to COMPILE SwiftTerm's Metal shader at build time. On Xcode 26 the
# Metal Toolchain is unbundled and the XcodeDefault `metal` stub fails to
# resolve the (cryptex-mounted) toolchain — so the universal build dies with
# "cannot execute tool 'metal' due to missing Metal Toolchain" (swiftlang/
# swift-package-manager#9429). The native build system instead COPIES the
# shader as a bundle resource (SwiftTerm compiles it at runtime), so it never
# invokes `metal` and needs no Metal Toolchain at all. Per-arch native builds
# + lipo give a working universal2 binary on plain Xcode 26.
if [ "$CONFIG" = "release" ]; then
  echo "==> swift build -c release (universal2 via per-arch native + lipo)"
  swift build --package-path "$ROOT" -c release --build-system native --arch arm64
  ARM_BIN="$(swift build --package-path "$ROOT" -c release --build-system native --arch arm64 --show-bin-path)/$APP_NAME"
  swift build --package-path "$ROOT" -c release --build-system native --arch x86_64
  X86_BIN="$(swift build --package-path "$ROOT" -c release --build-system native --arch x86_64 --show-bin-path)/$APP_NAME"
  [ -x "$ARM_BIN" ] || { echo "Error: arm64 binary not found at $ARM_BIN" >&2; exit 1; }
  [ -x "$X86_BIN" ] || { echo "Error: x86_64 binary not found at $X86_BIN" >&2; exit 1; }
  BIN="$ROOT/.build/${APP_NAME}-universal"
  echo "==> lipo -create (arm64 + x86_64) -> universal2"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$BIN"
else
  echo "==> swift build -c $CONFIG"
  swift build --package-path "$ROOT" -c "$CONFIG"
  BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/$APP_NAME"
fi

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
  <key>CFBundleDisplayName</key>     <string>Scrum Team for Claude Code</string>
  <key>CFBundleIdentifier</key>      <string>com.claude-scrum-team.${APP_NAME}</string>
  <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
${ICON_PLIST}  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Bundle the framework (Phase 3) into Contents/Resources/framework so a
# distributed .app is self-contained — no git clone required. We use
# `git archive HEAD` (tracked files at the built commit; for a release that is
# the tag) and drop dev-only trees. FrameworkLocator extracts this to
# ~/Library/Application Support/ScrumTeam/framework-<version>/ at first launch.
FW="$APP/Contents/Resources/framework"
echo "==> bundling framework into $FW"
rm -rf "$FW"; mkdir -p "$FW"
git -C "$ROOT/.." archive --format=tar HEAD | tar -x -C "$FW"
# Dev-only trees the runtime never needs (keeps the bundle small + clean).
rm -rf "$FW/macapp" "$FW/tests" "$FW/.github" "$FW/.claude" "$FW/images" \
       "$FW/.gitignore" "$FW/docs/superpowers"
if [ ! -f "$FW/scrum-start.sh" ] || [ ! -f "$FW/dashboard/app.py" ]; then
  echo "Error: bundled framework is missing scrum-start.sh / dashboard/app.py" >&2
  exit 1
fi

# Codesign. With a Developer ID identity we enable Hardened Runtime +
# entitlements (notarization prerequisite); otherwise an ad-hoc signature for
# local dev. NOTE: `--deep` applies one signature pass to the whole bundle and
# is fine while there is no embedded nested code. Once the framework + a Python
# interpreter are bundled (Phase 3), nested binaries must be signed inside-out
# by sign-and-notarize.sh, not with `--deep` here.
if [ -n "$SIGN_ID" ]; then
  echo "==> Developer ID codesign + Hardened Runtime ($SIGN_ID)"
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "==> ad-hoc codesign (local only — NOT distributable)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped/failed — app still runs locally)"
fi

echo "==> done: $APP"
echo "    arch: $(lipo -info "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/.*: //')"
echo "    open \"$APP\""
