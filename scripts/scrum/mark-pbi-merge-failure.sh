#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merge-failure.sh — record a merge failure attempt.
# Args: <pbi-id> <kind> <pre_head_sha> <detail>
#   kind=conflict|artifact_missing → detail is comma-separated paths
#   kind=regression                → detail is a single report_path
# Increments merge_failure_count; on count=3 promotes phase to escalated.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/derive.sh
source "$HERE/lib/derive.sh"

[ "$#" -eq 4 ] || fail E_INVALID_ARG "usage: mark-pbi-merge-failure.sh <pbi-id> <kind> <pre-head-sha> <detail>"
PBI="$1"; KIND="$2"; PRE="$3"; DETAIL="$4"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac
case "$KIND" in conflict|artifact_missing|regression) ;; *) fail E_INVALID_ARG "bad kind: $KIND" ;; esac
case "$PRE" in [0-9a-f]*) [ ${#PRE} -ge 7 ] || fail E_INVALID_ARG "pre-head sha too short" ;; *) fail E_INVALID_ARG "pre-head must be hex" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

PREV_COUNT="$(jq -r '.merge_failure_count // 0' "$STATE")"
NEW_COUNT=$((PREV_COUNT + 1))

# Build merge_failure object
case "$KIND" in
  conflict|artifact_missing)
    PATHS_JSON="$(printf '%s' "$DETAIL" | tr ',' '\n' | jq -R . | jq -s .)"
    MF="{\"kind\":\"$KIND\",\"pre_head_at_failure\":\"$PRE\",\"paths\":$PATHS_JSON}"
    ;;
  regression)
    MF="{\"kind\":\"regression\",\"pre_head_at_failure\":\"$PRE\",\"report_path\":\"$DETAIL\"}"
    ;;
esac

# Decide phase: escalate at 3rd failure
if [ "$NEW_COUNT" -ge 3 ]; then
  NEW_PHASE="escalated"
  EXPR=".phase = \"escalated\" | .escalation_reason = \"stagnation\" | .merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
else
  case "$KIND" in
    conflict)          NEW_PHASE="merge_conflict" ;;
    artifact_missing)  NEW_PHASE="merge_artifact_missing" ;;
    regression)        NEW_PHASE="merge_regression" ;;
  esac
  EXPR=".phase = \"$NEW_PHASE\" | .merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
fi

atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Project to backlog
DERIVED="$(derive_backlog_status_from_phase "$NEW_PHASE")"
BACKLOG=".scrum/backlog.json"
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
if [ -f "$BACKLOG" ] && jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$BACKLOG" >/dev/null; then
  atomic_write "$BACKLOG" "(.items[] | select(.id == \"$PBI\")).status = \"$DERIVED\"" "$BACKLOG_SCHEMA"
fi

printf '[mark-pbi-merge-failure] %s kind=%s count=%d phase=%s\n' "$PBI" "$KIND" "$NEW_COUNT" "$NEW_PHASE"
