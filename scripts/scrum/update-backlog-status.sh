#!/usr/bin/env bash
# scripts/scrum/update-backlog-status.sh — set a PBI's status in .scrum/backlog.json.
# Usage: update-backlog-status.sh <pbi-id> <status>
#
# Status is the sole SSOT for PBI lifecycle (12-value enum). All actors write
# this directly through the wrapper; there is no derived projection from
# pbi-state.json anymore.
#
# Status enum (matches docs/contracts/scrum-state/backlog.schema.json):
#   SM-managed:   draft, refined, blocked, awaiting_cross_review,
#                 cross_review, escalated, done
#   Dev-managed:  in_progress_design, in_progress_impl, in_progress_pbi_review,
#                 in_progress_ut_run, in_progress_merge
#
# Actor ownership above is a doc-only convention (see CLAUDE.md "PBI
# status flow" and docs/data-model.md "State Transitions"). This wrapper
# does NOT enforce which actor calls it for which transition — agents
# are trusted to follow the documented graph. Adding machine-level
# enforcement would require an --as-actor flag and a transition table;
# that is out of scope for this wrapper.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: update-backlog-status.sh <pbi-id> <status>"
PBI="$1"; STATUS="$2"
assert_pbi_id "$PBI"
case "$STATUS" in
  draft|refined|blocked|\
in_progress_design|in_progress_impl|in_progress_pbi_review|\
in_progress_ut_run|in_progress_merge|\
awaiting_cross_review|cross_review|escalated|done) ;;
  *) fail E_INVALID_ARG "bad status: $STATUS" ;;
esac

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"

# Pre-check existence of the pbi-id (atomic_write cannot tell us "not found")
pbi_in_backlog "$PBI" "$PATHF" || fail E_INVALID_ARG "pbi not found: $PBI"

atomic_write "$PATHF" \
  "(.items[] | select(.id == \"$PBI\")).status = \"$STATUS\"" \
  "$SCHEMA"
