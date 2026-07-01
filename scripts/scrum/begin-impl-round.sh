#!/usr/bin/env bash
# scripts/scrum/begin-impl-round.sh — start (or resume) an impl Round for a PBI.
# Usage: begin-impl-round.sh <pbi-id>
# Prints the new (or current) impl_round number to stdout.
#
# Atomic, idempotent: on mutation increments `impl_round` and resets
# `impl_status` / `ut_status` to `pending`, then idempotently sets
# backlog status to `in_progress_impl`. The Round counter is owned by
# this wrapper — agents MUST NOT compute it themselves and write via
# update-pbi-state.sh.
#
# Decision rule:
#   impl_status == "pending" AND impl_round > 0
#     → Round already started (likely respawn after crash). Print the
#       current impl_round; do NOT mutate state.
#   otherwise
#     → impl_round += 1; impl_status = "pending"; ut_status = "pending".
#
# Legal backlog pre-states (anything else is rejected):
#   in_progress_design       — Design success → first impl Round
#   in_progress_pbi_review   — PBI Review FAIL → next impl Round
#   in_progress_ut_run       — UT Run FAIL → next impl Round
#   cross_review             — Cross Review aspect 1/2/3 FAIL → next impl Round
#   in_progress_impl         — Re-entry (after respawn, or after a caller
#                              transitioned backlog before invoking this)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: begin-impl-round.sh <pbi-id>"
PBI="$1"
assert_pbi_id "$PBI"

STATE_FILE=".scrum/pbi/$PBI/state.json"
BACKLOG_FILE=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

[ -f "$STATE_FILE" ] || fail E_FILE_MISSING "$STATE_FILE (initialise via init-pbi-state.sh)"
[ -f "$BACKLOG_FILE" ] || fail E_FILE_MISSING "$BACKLOG_FILE"

pbi_in_backlog "$PBI" "$BACKLOG_FILE" || fail E_INVALID_ARG "pbi not found in backlog: $PBI"

CURRENT_BACKLOG_STATUS="$(get_pbi_status "$PBI" "$BACKLOG_FILE")"
case "$CURRENT_BACKLOG_STATUS" in
  in_progress_design|in_progress_pbi_review|in_progress_ut_run|cross_review|in_progress_impl) ;;
  *)
    fail E_INVALID_ARG \
      "begin-impl-round: illegal pre-state '$CURRENT_BACKLOG_STATUS' (expected one of: in_progress_design, in_progress_pbi_review, in_progress_ut_run, cross_review, in_progress_impl)"
    ;;
esac

CURRENT_ROUND="$(jq -r '.impl_round' "$STATE_FILE")"
CURRENT_IMPL_STATUS="$(jq -r '.impl_status' "$STATE_FILE")"

case "$CURRENT_ROUND" in
  ''|*[!0-9]*) fail E_SCHEMA "impl_round in $STATE_FILE is not a non-negative integer: $CURRENT_ROUND" ;;
esac

if [ "$CURRENT_IMPL_STATUS" = "pending" ] && [ "$CURRENT_ROUND" -gt 0 ]; then
  NEW_ROUND="$CURRENT_ROUND"
else
  NEW_ROUND=$(( CURRENT_ROUND + 1 ))
  atomic_write "$STATE_FILE" \
    ".impl_round = $NEW_ROUND | .impl_status = \"pending\" | .ut_status = \"pending\"" \
    "$SCHEMA"
fi

if [ "$CURRENT_BACKLOG_STATUS" != "in_progress_impl" ]; then
  "$HERE/update-backlog-status.sh" "$PBI" in_progress_impl
fi

printf '%s\n' "$NEW_ROUND"
