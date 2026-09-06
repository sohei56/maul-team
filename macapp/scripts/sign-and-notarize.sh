#!/usr/bin/env bash
#
# MaulTeam for Mac
# Copyright (c) 2026 sohei56. All rights reserved.
#
# Source-available; NOT covered by this repository's MIT License.
# See macapp/LICENSE for terms.
#
# sign-and-notarize.sh — notarize + staple a Developer-ID-signed MaulTeam build.
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
#     app  — notarize + staple build/MaulTeam.app
#     dmg  — notarize + staple the newest build/MaulTeam-*.dmg
#     all  — app, then run make-dmg.sh, then dmg (local one-shot)
#
# Auth (pick ONE; keychain profile is easiest locally):
#   NOTARY_PROFILE=<name>              # `xcrun notarytool store-credentials`
#   — or —
#   NOTARY_KEY_ID / NOTARY_ISSUER_ID and one of:
#     NOTARY_KEY_PATH=/path/to/AuthKey_XXXX.p8   (local: a file on disk)
#     NOTARY_KEY_P8=<base64 of the .p8>          (CI: from a GitHub secret)
#
# Transient-network tuning (all optional — see "Notary round trip" below):
#   NOTARY_MAX_ATTEMPTS=5        # attempts for the upload and for the poll
#   NOTARY_BACKOFF_BASE=15       # first retry delay (seconds), doubles each time
#   NOTARY_BACKOFF_MAX=240       # cap on the doubled delay
#   NOTARY_OUTPUT_FORMAT=json    # set empty to use notarytool's human output
#
# POSIX sh compatible (invoked as `sh sign-and-notarize.sh …` by release.yml and
# the runbook): no bash arrays or process substitution.
set -euo pipefail

MODE="${1:-all}"
APP_NAME="MaulTeam"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/${APP_NAME}.app"

# Bounded-retry budget for the notary round trip. `${VAR-default}` (no colon) on
# NOTARY_OUTPUT_FORMAT so an explicitly EMPTY value is honoured as "human output".
NOTARY_MAX_ATTEMPTS="${NOTARY_MAX_ATTEMPTS:-5}"
NOTARY_BACKOFF_BASE="${NOTARY_BACKOFF_BASE:-15}"
NOTARY_BACKOFF_MAX="${NOTARY_BACKOFF_MAX:-240}"
NOTARY_OUTPUT_FORMAT="${NOTARY_OUTPUT_FORMAT-json}"

TMP_P8=""
# `return 0`: this runs as an EXIT trap under `set -e`, and a trap whose last
# command fails makes the shell exit non-zero — so the bare `[ -n "$TMP_P8" ]`
# test failing (keychain-profile mode, where no temp key was written) would
# otherwise turn a fully successful run into exit 1.
cleanup() { [ -n "$TMP_P8" ] && rm -f "$TMP_P8"; return 0; }
trap cleanup EXIT

# Resolve notary credentials once. Either NOTARY_PROFILE is used as-is, or a key
# file is resolved into NOTARY_KEY_FILE (decoding NOTARY_KEY_P8 to a temp file
# when only the base64 form is given). notarytool_run() reads these.
NOTARY_KEY_FILE=""
resolve_notary_auth() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    return
  fi
  if [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER_ID:-}" ]; then
    echo "Error: set NOTARY_PROFILE, or NOTARY_KEY_ID + NOTARY_ISSUER_ID + a key." >&2
    exit 2
  fi
  NOTARY_KEY_FILE="${NOTARY_KEY_PATH:-}"
  if [ -z "$NOTARY_KEY_FILE" ]; then
    if [ -z "${NOTARY_KEY_P8:-}" ]; then
      echo "Error: provide NOTARY_KEY_PATH (file) or NOTARY_KEY_P8 (base64)." >&2
      exit 2
    fi
    TMP_P8="$(mktemp -t notary-key.XXXXXX)"
    printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$TMP_P8"
    NOTARY_KEY_FILE="$TMP_P8"
  fi
  [ -f "$NOTARY_KEY_FILE" ] || { echo "Error: notary key not found at $NOTARY_KEY_FILE" >&2; exit 2; }
}

# ── Notary round trip ────────────────────────────────────────────────────────
# The upload and the status poll are SEPARATE connections to Apple. A release
# run once lost only the poll — "Successfully uploaded file" was already in the
# log when notarytool died with NSURLErrorDomain Code=-1009 ("The Internet
# connection appears to be offline") against appstoreconnect.apple.com, failing
# the job over a submission Apple had accepted. So: submit WITHOUT --wait, keep
# the submission id, and poll it in a bounded retry loop. A definitive Apple
# verdict (Invalid / Rejected) is NEVER retried — only a broken connection is.

# Run one notarytool subcommand with whichever credential mode is configured.
# $1 = subcommand (submit | wait | log), $2… = its arguments.
notarytool_run() {
  _sub="$1"
  shift
  if [ -n "$NOTARY_OUTPUT_FORMAT" ]; then
    set -- "$@" --output-format "$NOTARY_OUTPUT_FORMAT"
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool "$_sub" "$@" --keychain-profile "$NOTARY_PROFILE"
  else
    xcrun notarytool "$_sub" "$@" \
      --key "$NOTARY_KEY_FILE" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID"
  fi
}

# Pull the submission id out of notarytool output. Tolerates BOTH the JSON form
# (`"id":"<uuid>"`) and the human form (`  id: <uuid>`), so the parse survives
# NOTARY_OUTPUT_FORMAT being emptied on a notarytool that lacks the flag.
# Call as `id="$(extract_submission_id "$out" || true)"`: under `set -o
# pipefail` the `head -1` can close the pipe on sed (SIGPIPE → 141) after the
# value has already been printed.
extract_submission_id() {
  printf '%s\n' "$1" \
    | sed -n \
        -e 's/.*"id"[[:space:]]*:[[:space:]]*"\([0-9A-Za-z-]\{8,\}\)".*/\1/p' \
        -e 's/^[[:space:]]*id:[[:space:]]*\([0-9A-Za-z-]\{8,\}\)[[:space:]]*$/\1/p' \
    | head -1
}

# Sleep before the next attempt, or return 1 once the budget is spent.
# $1 = step name (for the log), $2 = attempt that just failed, $3 = delay (s).
notary_backoff() {
  if [ "$2" -ge "$NOTARY_MAX_ATTEMPTS" ]; then
    echo "Error: notarytool $1 kept failing after $NOTARY_MAX_ATTEMPTS attempt(s)." >&2
    return 1
  fi
  echo "==> transient notarytool $1 failure (attempt $2/$NOTARY_MAX_ATTEMPTS) — retrying in ${3}s"
  sleep "$3"
}

# Upload an artifact; the accepted submission id lands in SUBMISSION_ID and
# notarytool's own output is echoed through to the build log. Retries only while
# no id has been obtained — an id means Apple already has the bytes, so the
# upload is never repeated after that. $1 = path to the .zip / .dmg.
SUBMISSION_ID=""
notary_upload() {
  _up_attempt=1
  _up_delay="$NOTARY_BACKOFF_BASE"
  SUBMISSION_ID=""
  while :; do
    _up_out="$(notarytool_run submit "$1" 2>&1)" && _up_rc=0 || _up_rc=$?
    printf '%s\n' "$_up_out"
    SUBMISSION_ID="$(extract_submission_id "$_up_out" || true)"
    if [ -n "$SUBMISSION_ID" ]; then
      return 0
    fi
    if [ "$_up_rc" -eq 0 ]; then
      echo "Error: notarytool submit reported success but printed no submission id." >&2
      return 1
    fi
    if ! notary_backoff submit "$_up_attempt" "$_up_delay"; then
      return 1
    fi
    _up_attempt=$((_up_attempt + 1))
    _up_delay=$((_up_delay * 2))
    if [ "$_up_delay" -gt "$NOTARY_BACKOFF_MAX" ]; then
      _up_delay="$NOTARY_BACKOFF_MAX"
    fi
  done
}

# Poll a submission to a verdict. $1 = submission id.
#
# Success requires the word Accepted in the output, not merely exit 0 — that is
# strictly stricter than the old `submit --wait`, which trusted the exit status
# alone. Invalid / Rejected is Apple's final answer: dump the notary log and
# fail immediately. Anything else that exited non-zero is treated as a broken
# connection and retried.
notary_poll() {
  _pl_attempt=1
  _pl_delay="$NOTARY_BACKOFF_BASE"
  while :; do
    _pl_out="$(notarytool_run wait "$1" 2>&1)" && _pl_rc=0 || _pl_rc=$?
    printf '%s\n' "$_pl_out"
    case "$_pl_out" in
      *Invalid*|*Rejected*)
        echo "Error: Apple returned a final verdict for $1 — not retried." >&2
        echo "==> notarytool log ($1)" >&2
        notarytool_run log "$1" >&2 || true
        return 1
        ;;
      *Accepted*)
        return 0
        ;;
    esac
    if [ "$_pl_rc" -eq 0 ]; then
      echo "Error: notarytool wait exited 0 without an Accepted status for $1." >&2
      return 1
    fi
    if ! notary_backoff wait "$_pl_attempt" "$_pl_delay"; then
      return 1
    fi
    _pl_attempt=$((_pl_attempt + 1))
    _pl_delay=$((_pl_delay * 2))
    if [ "$_pl_delay" -gt "$NOTARY_BACKOFF_MAX" ]; then
      _pl_delay="$NOTARY_BACKOFF_MAX"
    fi
  done
}

# Submit an artifact to Apple's notary service and block until it is judged.
# $1 = path to the .zip / .dmg to submit.
notary_submit() {
  notary_upload "$1"
  echo "==> notarytool wait ($SUBMISSION_ID)"
  notary_poll "$SUBMISSION_ID"
}

# Refuse to notarize an ad-hoc signature — Apple rejects it and the failure is
# confusing. make-app.sh must have run with DEVELOPER_ID_APP set.
#
# Capture into a variable and match with `case` rather than piping to `grep -q`:
# under `set -o pipefail`, grep -q closes the pipe on first match, codesign dies
# with SIGPIPE (141), and the pipeline is reported as failed even though it
# matched — which would wrongly flag a properly-signed app as ad-hoc.
assert_developer_id_signed() {
  info="$(codesign -dvv "$1" 2>&1 || true)"
  case "$info" in
    *"Authority=Developer ID Application"*) return 0 ;;
  esac
  echo "Error: $1 is not Developer ID signed (ad-hoc or unsigned)." >&2
  echo "       Run: DEVELOPER_ID_APP='Developer ID Application: … (TEAMID)' \\" >&2
  echo "            sh macapp/scripts/make-app.sh release" >&2
  exit 1
}

newest_dmg() {
  # The *.dmg glob already excludes the *.dmg.sha256 sidecars; -t = newest first.
  # shellcheck disable=SC2012  # filenames are ours (MaulTeam-<ver>.dmg), no newlines
  ls -t "$BUILD"/"${APP_NAME}"-*.dmg 2>/dev/null | head -1
}

notarize_app() {
  [ -d "$APP" ] || { echo "Error: $APP not found — run make-app.sh release first" >&2; exit 1; }
  assert_developer_id_signed "$APP"
  zip="$BUILD/${APP_NAME}-notarize.zip"
  echo "==> zipping app for submission"
  rm -f "$zip"
  # ditto --keepParent preserves the .app wrapper the notary service expects.
  ditto -c -k --keepParent "$APP" "$zip"
  echo "==> notarytool submit (app) — waiting for Apple"
  notary_submit "$zip"
  rm -f "$zip"
  echo "==> stapling ticket to the .app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> spctl assessment (exec)"
  spctl -a -vvv -t exec "$APP"
}

notarize_dmg() {
  # `|| true`: newest_dmg's `ls | head` can exit 141 (head closes the pipe →
  # ls SIGPIPE) under pipefail; the first line is already captured correctly.
  dmg="$(newest_dmg || true)"
  [ -n "$dmg" ] || { echo "Error: no $BUILD/${APP_NAME}-*.dmg — run make-dmg.sh first" >&2; exit 1; }
  assert_developer_id_signed "$dmg"
  echo "==> notarytool submit (dmg: $(basename "$dmg")) — waiting for Apple"
  notary_submit "$dmg"
  echo "==> stapling ticket to the .dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  echo "==> spctl assessment (dmg / primary signature)"
  spctl -a -vvv -t open --context context:primary-signature "$dmg"
}

# Guarded so tests/unit/macapp/test_sign_and_notarize.bats can source this file
# (SIGN_NOTARIZE_SOURCED=1) and drive the notary functions against a fake xcrun
# without running the real pipeline.
if [ "${SIGN_NOTARIZE_SOURCED:-0}" != "1" ]; then
  resolve_notary_auth
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
fi
