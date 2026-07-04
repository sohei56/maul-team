#!/usr/bin/env bash
# sign-and-notarize.sh — notarize + staple a Developer-ID-signed ScrumTeam build.
#
# make-app.sh already CODESIGNS the .app (Developer ID + Hardened Runtime) and
# make-dmg.sh signs the .dmg. This script does the remaining, Apple-online part:
# submit the artifact to Apple's notary service, wait for the ticket, staple it
# to the artifact, and prove Gatekeeper acceptance. It is the Phase 2 entry
# point for a LOCAL end-to-end verification (the same steps run in
# .github/workflows/release.yml on a Release publish).
#
# Both the .app AND the .dmg are notarized+stapled. Stapling the .app matters:
# once a user drags it out of the .dmg, an app WITHOUT a stapled ticket only
# passes Gatekeeper via an online check — offline first-launch would warn. A
# stapled app passes offline. (release.yml previously stapled only the .dmg.)
#
# Usage:
#   sign-and-notarize.sh [app|dmg|all]   # default: all
#     app  — notarize + staple build/ScrumTeam.app
#     dmg  — notarize + staple the newest build/ScrumTeam-*.dmg
#     all  — app, then run make-dmg.sh, then dmg (local one-shot)
#
# Auth (pick ONE; keychain profile is easiest locally):
#   NOTARY_PROFILE=<name>              # `xcrun notarytool store-credentials`
#   — or —
#   NOTARY_KEY_ID / NOTARY_ISSUER_ID and one of:
#     NOTARY_KEY_PATH=/path/to/AuthKey_XXXX.p8   (local: a file on disk)
#     NOTARY_KEY_P8=<base64 of the .p8>          (CI: from a GitHub secret)
set -euo pipefail

MODE="${1:-all}"
APP_NAME="ScrumTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/${APP_NAME}.app"

# --- notarytool auth args ---------------------------------------------------
# Emits the credential flags on stdout; decodes a base64 .p8 to a temp file
# when NOTARY_KEY_P8 is used. TMP_P8 is cleaned up on exit.
TMP_P8=""
cleanup() { [ -n "$TMP_P8" ] && rm -f "$TMP_P8"; }
trap cleanup EXIT

notary_auth_args() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    printf '%s\0%s\0' --keychain-profile "$NOTARY_PROFILE"
    return
  fi
  if [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER_ID:-}" ]; then
    echo "Error: set NOTARY_PROFILE, or NOTARY_KEY_ID + NOTARY_ISSUER_ID + a key." >&2
    exit 2
  fi
  local key="${NOTARY_KEY_PATH:-}"
  if [ -z "$key" ]; then
    if [ -z "${NOTARY_KEY_P8:-}" ]; then
      echo "Error: provide NOTARY_KEY_PATH (file) or NOTARY_KEY_P8 (base64)." >&2
      exit 2
    fi
    TMP_P8="$(mktemp -t notary-key)"
    printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$TMP_P8"
    key="$TMP_P8"
  fi
  [ -f "$key" ] || { echo "Error: notary key not found at $key" >&2; exit 2; }
  printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
    --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
}

# Refuse to notarize an ad-hoc signature — Apple rejects it and the failure is
# confusing. make-app.sh must have run with DEVELOPER_ID_APP set.
assert_developer_id_signed() {
  local target="$1"
  if ! codesign -dvv "$target" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "Error: $target is not Developer ID signed (ad-hoc or unsigned)." >&2
    echo "       Run: DEVELOPER_ID_APP='Developer ID Application: … (TEAMID)' \\" >&2
    echo "            sh macapp/scripts/make-app.sh release" >&2
    exit 1
  fi
}

# Read the auth args into a NUL-delimited array once, so a key path with spaces
# survives and we never re-decode the p8.
read_auth() {
  AUTH=()
  local field
  while IFS= read -r -d '' field; do AUTH+=("$field"); done < <(notary_auth_args)
  # notary_auth_args' `exit` runs in the process-substitution subshell and does
  # not propagate; an empty AUTH is its failure signal (it printed why already).
  [ "${#AUTH[@]}" -gt 0 ] || exit 2
}

notarize_app() {
  [ -d "$APP" ] || { echo "Error: $APP not found — run make-app.sh release first" >&2; exit 1; }
  assert_developer_id_signed "$APP"
  local zip="$BUILD/${APP_NAME}-notarize.zip"
  echo "==> zipping app for submission"
  rm -f "$zip"
  # ditto --keepParent preserves the .app wrapper the notary service expects.
  ditto -c -k --keepParent "$APP" "$zip"
  echo "==> notarytool submit (app) — waiting for Apple"
  xcrun notarytool submit "$zip" "${AUTH[@]}" --wait
  rm -f "$zip"
  echo "==> stapling ticket to the .app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> spctl assessment (exec)"
  spctl -a -vvv -t exec "$APP"
}

newest_dmg() {
  # The *.dmg glob already excludes the *.dmg.sha256 sidecars; -t = newest first.
  # shellcheck disable=SC2012  # filenames are ours (ScrumTeam-<ver>.dmg), no newlines
  ls -t "$BUILD"/"${APP_NAME}"-*.dmg 2>/dev/null | head -1
}

notarize_dmg() {
  local dmg; dmg="$(newest_dmg)"
  [ -n "$dmg" ] || { echo "Error: no $BUILD/${APP_NAME}-*.dmg — run make-dmg.sh first" >&2; exit 1; }
  assert_developer_id_signed "$dmg"
  echo "==> notarytool submit (dmg: $(basename "$dmg")) — waiting for Apple"
  xcrun notarytool submit "$dmg" "${AUTH[@]}" --wait
  echo "==> stapling ticket to the .dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  echo "==> spctl assessment (dmg / primary signature)"
  spctl -a -vvv -t open --context context:primary-signature "$dmg"
}

read_auth
case "$MODE" in
  app) notarize_app ;;
  dmg) notarize_dmg ;;
  all)
    notarize_app
    echo "==> make-dmg.sh (packaging the stapled app)"
    sh "$ROOT/scripts/make-dmg.sh"
    notarize_dmg
    ;;
  *) echo "Usage: sign-and-notarize.sh [app|dmg|all]" >&2; exit 2 ;;
esac

echo "==> notarization complete ($MODE)"
