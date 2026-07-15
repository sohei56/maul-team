#!/usr/bin/env bash
# scripts/scrum/update-backlog-status.sh — set a PBI's status in .scrum/backlog.json.
# Usage: update-backlog-status.sh <pbi-id> <status>
#
# Status is the sole SSOT for PBI lifecycle (13-value enum). All actors write
# this directly through the wrapper; there is no derived projection from
# pbi-state.json anymore.
#
# Status enum (matches docs/contracts/scrum-state/backlog.schema.json):
#   SM-managed:   draft, refined, blocked, awaiting_cross_review,
#                 cross_review, escalated, done, cancelled
#   Dev-managed:  in_progress_design, in_progress_impl, in_progress_pbi_review,
#                 in_progress_ut_run, in_progress_merge
#
# Actor ownership above is a doc-only convention (see CLAUDE.md "PBI
# status flow" and docs/data-model.md "State Transitions"). This wrapper
# does NOT enforce which actor calls it for which transition — agents
# are trusted to follow the documented graph. Adding machine-level
# enforcement would require an --as-actor flag and a transition table;
# that is out of scope for this wrapper.
#
# One content gate IS enforced: a transition into `refined` requires a
# non-empty `demo_plan` on the item when its kind is `code` (kind=docs
# is exempt — the doc itself is the demo). See backlog.schema.json and
# skills/backlog-refinement/SKILL.md Step 3.c2.
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
awaiting_cross_review|cross_review|escalated|done|cancelled) ;;
  *) fail E_INVALID_ARG "bad status: $STATUS" ;;
esac

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"

# Pre-check existence of the pbi-id (atomic_write cannot tell us "not found")
pbi_in_backlog "$PBI" "$PATHF" || fail E_INVALID_ARG "pbi not found: $PBI"

# Demo-plan gate: a PBI only becomes `refined` once refinement has decided how
# it will be demonstrated locally at Sprint Review (kind=docs exempt).
if [ "$STATUS" = "refined" ]; then
  jq -e --arg id "$PBI" '
    .items[] | select(.id == $id)
    | ((.kind // "code") == "docs") or (((.demo_plan // "") | length) > 0)
  ' "$PATHF" >/dev/null \
    || fail E_INVALID_ARG \
      "refined requires non-empty demo_plan for kind=code (set via set-backlog-item-field.sh $PBI demo_plan '<how to demo locally>')"
fi

# Stamp updated_at alongside the status change. atomic_write's auto-touch only
# fires on a top-level updated_at (backlog.json has none), so the item's field
# must be set explicitly here. $now is bound by atomic_write via `--arg now`
# (same ISO-8601 UTC format add-backlog-item.sh seeds created_at/updated_at).
atomic_write "$PATHF" \
  "(.items[] | select(.id == \"$PBI\")) |= (.status = \"$STATUS\" | .updated_at = \$now)" \
  "$SCHEMA"
