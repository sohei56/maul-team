#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merge-failure.sh — record a merge failure attempt.
# Args: <pbi-id> <kind> <pre_head_sha> <detail>
#   kind=conflict|artifact_missing → detail is comma-separated paths
#   kind=regression               → detail is the regression log path
# Increments merge_failure_count; on count=3 escalates (status=escalated +
# escalation_reason mapped from kind). Below 3, leaves backlog status
# untouched (typically already in_progress_merge from mark-pbi-ready-to-merge).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 4 ] || fail E_INVALID_ARG "usage: mark-pbi-merge-failure.sh <pbi-id> <kind> <pre-head-sha> <detail>"
PBI="$1"; KIND="$2"; PRE="$3"; DETAIL="$4"
assert_pbi_id "$PBI"
case "$KIND" in conflict|artifact_missing|regression) ;; *) fail E_INVALID_ARG "bad kind: $KIND" ;; esac
assert_hex_sha pre-head-sha "$PRE"

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

PREV_COUNT="$(jq -r '.merge_failure_count // 0' "$STATE")"
NEW_COUNT=$((PREV_COUNT + 1))

# Build merge_failure object
PATHS_JSON="$(printf '%s' "$DETAIL" | tr ',' '\n' | jq -R . | jq -s .)"
MF="{\"kind\":\"$KIND\",\"pre_head_at_failure\":\"$PRE\",\"paths\":$PATHS_JSON}"

# Map kind → escalation_reason for the escalated case.
case "$KIND" in
  conflict)          ESC_REASON="merge_conflict" ;;
  artifact_missing)  ESC_REASON="merge_artifact_missing" ;;
  regression)        ESC_REASON="merge_regression" ;;
  *)                 fail E_INVALID_ARG "bad kind: $KIND" ;;
esac

if [ "$NEW_COUNT" -ge 3 ]; then
  EXPR=".escalation_reason = \"$ESC_REASON\" | .merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
else
  EXPR=".merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
fi

atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Backlog status: only flip on escalation (count >= 3). Below that, the PBI
# stays at its current status (typically in_progress_merge) so the Developer
# can fix and retry.
if [ "$NEW_COUNT" -ge 3 ]; then
  BACKLOG=".scrum/backlog.json"
  if pbi_in_backlog "$PBI" "$BACKLOG"; then
    "$HERE/update-backlog-status.sh" "$PBI" escalated
  fi
fi

printf '[mark-pbi-merge-failure] %s kind=%s count=%d reason=%s\n' \
  "$PBI" "$KIND" "$NEW_COUNT" "$([ "$NEW_COUNT" -ge 3 ] && echo "$ESC_REASON" || echo "(retry)")"
