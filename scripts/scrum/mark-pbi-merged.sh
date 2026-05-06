#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merged.sh — record successful merge into main.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/derive.sh
source "$HERE/lib/derive.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: mark-pbi-merged.sh <pbi-id> <merged-sha>"
PBI="$1"; SHA="$2"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac
case "$SHA" in
  [0-9a-f]*) [ "${#SHA}" -ge 7 ] && [ "${#SHA}" -le 40 ] || fail E_INVALID_ARG "merged-sha length 7..40 required" ;;
  *) fail E_INVALID_ARG "merged-sha must be hex" ;;
esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PREV="$(jq -r '.phase' "$STATE")"
[ "$PREV" = "ready_to_merge" ] || fail E_INVALID_ARG "expected phase=ready_to_merge, got $PREV"

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EXPR=".phase = \"merged\" | .merged_sha = \"$SHA\" | .merged_at = \"$NOW\" | .merge_failure_count = 0"
atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Mirror merged_sha + merged_at to backlog item; status from derive (SSOT).
DERIVED="$(derive_backlog_status_from_phase merged)"
BACKLOG=".scrum/backlog.json"
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
if [ -f "$BACKLOG" ] && jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$BACKLOG" >/dev/null; then
  EXPR_B="(.items[] | select(.id == \"$PBI\")).merged_sha = \"$SHA\" | (.items[] | select(.id == \"$PBI\")).merged_at = \"$NOW\" | (.items[] | select(.id == \"$PBI\")).status = \"$DERIVED\""
  atomic_write "$BACKLOG" "$EXPR_B" "$BACKLOG_SCHEMA"
fi

printf '[mark-pbi-merged] %s @ %s\n' "$PBI" "$SHA"
