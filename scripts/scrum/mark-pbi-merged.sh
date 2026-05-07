#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merged.sh — record successful merge into main.
# Sets merged_sha + merged_at on pbi-state.json (resets merge_failure_count),
# mirrors them to backlog item, and flips backlog status to awaiting_cross_review.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: mark-pbi-merged.sh <pbi-id> <merged-sha>"
PBI="$1"; SHA="$2"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac
case "$SHA" in
  [0-9a-f]*) [ "${#SHA}" -ge 7 ] && [ "${#SHA}" -le 40 ] || fail E_INVALID_ARG "merged-sha length 7..40 required" ;;
  *) fail E_INVALID_ARG "merged-sha must be hex" ;;
esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

# Gate: backlog status must be in_progress_merge before merging.
BACKLOG=".scrum/backlog.json"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG"
PREV_STATUS="$(get_pbi_status "$PBI" "$BACKLOG")"
[ "$PREV_STATUS" = "in_progress_merge" ] \
  || fail E_INVALID_ARG "expected backlog status=in_progress_merge, got '$PREV_STATUS'"

NOW="$(_iso_utc_now)"
# On success, drop `merge_failure` so a stale failure record from a prior
# retry does not survive into the post-merge state. (Schema declares
# `merge_failure` as a non-nullable object — `del()` is the only safe clear.)
EXPR=".merged_sha = \"$SHA\" | .merged_at = \"$NOW\" | .merge_failure_count = 0 | del(.merge_failure)"
atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Mirror merged_sha + merged_at to backlog item (status flip happens via wrapper below).
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
EXPR_B="(.items[] | select(.id == \"$PBI\")).merged_sha = \"$SHA\""
EXPR_B="$EXPR_B | (.items[] | select(.id == \"$PBI\")).merged_at = \"$NOW\""
atomic_write "$BACKLOG" "$EXPR_B" "$BACKLOG_SCHEMA"

# Flip backlog status to awaiting_cross_review (Sprint-end cross_review待機).
"$HERE/update-backlog-status.sh" "$PBI" awaiting_cross_review

printf '[mark-pbi-merged] %s @ %s\n' "$PBI" "$SHA"
