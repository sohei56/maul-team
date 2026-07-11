#!/usr/bin/env bash
# scripts/scrum/rollover-sprint.sh — archive a COMPLETED Sprint and clear
# sprint.json so the next Sprint can be initialised.
#
# Without this wrapper the team cannot advance past Sprint 1:
#   - init-sprint.sh refuses while .scrum/sprint.json exists, and
#   - freeze-sprint-base.sh refuses while base_sha is already frozen.
# This script closes that gap by:
#   1. archiving the completed sprint.json into .scrum/sprint-history.json
#      (via append-sprint-history.sh — append-only, idempotent on id), then
#   2. removing sprint.json so init-sprint.sh can create the next Sprint and
#      freeze-sprint-base.sh can capture a fresh base_sha = new main HEAD.
#
# Refuses unless sprint.json.status == "complete" (never discards an in-flight
# Sprint). Idempotent: if sprint.json is already gone it is a no-op success, so
# a retried autonomous iteration does not fail here.
#
# PBI counts are derived from the Sprint Backlog (items whose sprint_id matches
# the rolled-over Sprint); they are omitted when backlog.json is absent.
#
# Usage: rollover-sprint.sh
#
# Echoes the archived Sprint id on stdout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

SPRINT=".scrum/sprint.json"
BACKLOG=".scrum/backlog.json"
STATE=".scrum/state.json"
STATE_SCHEMA="$ROOT/docs/contracts/scrum-state/state.schema.json"

# Idempotent no-op: nothing to roll over (e.g. retried iteration).
if [ ! -f "$SPRINT" ]; then
  printf '[rollover-sprint] no sprint.json — nothing to roll over (no-op)\n' >&2
  exit 0
fi

STATUS="$(jq -r '.status // empty' "$SPRINT" 2>/dev/null || true)"
[ "$STATUS" = "complete" ] \
  || fail E_INVALID_ARG "refuse to roll over sprint in status=${STATUS:-unknown} (need complete)"

SPRINT_ID="$(jq -r '.id // empty' "$SPRINT")"
[ -n "$SPRINT_ID" ] || fail E_INVALID_ARG "sprint.json has no id"

GOAL="$(jq -r '.goal // empty' "$SPRINT")"
# sprint.json permits a null goal; the history schema requires a non-empty
# string, so fall back to an explicit placeholder.
[ -n "$GOAL" ] || GOAL="(no goal recorded)"
TYPE="$(jq -r '.type // "development"' "$SPRINT")"
STARTED_AT="$(jq -r '.started_at // empty' "$SPRINT")"
COMPLETED_AT="$(jq -r '.completed_at // empty' "$SPRINT")"

# Derive PBI counts from the Sprint Backlog (best-effort; omitted if absent).
# cancelled PBIs are descoped work, not undelivered work — excluded from total.
PBIS_TOTAL=""
PBIS_COMPLETED=""
if [ -f "$BACKLOG" ]; then
  PBIS_TOTAL="$(jq --arg id "$SPRINT_ID" \
    '[.items[]? | select(.sprint_id == $id and .status != "cancelled")] | length' "$BACKLOG" 2>/dev/null || echo "")"
  PBIS_COMPLETED="$(jq --arg id "$SPRINT_ID" \
    '[.items[]? | select(.sprint_id == $id and .status == "done")] | length' "$BACKLOG" 2>/dev/null || echo "")"
fi

# 1. Archive into sprint-history.json (append-only, idempotent on id).
HIST_ARGS=(--id "$SPRINT_ID" --goal "$GOAL" --type "$TYPE")
if [ -n "$STARTED_AT" ];     then HIST_ARGS+=(--started-at "$STARTED_AT"); fi
if [ -n "$COMPLETED_AT" ];   then HIST_ARGS+=(--completed-at "$COMPLETED_AT"); fi
if [ -n "$PBIS_TOTAL" ];     then HIST_ARGS+=(--pbis-total "$PBIS_TOTAL"); fi
if [ -n "$PBIS_COMPLETED" ]; then HIST_ARGS+=(--pbis-completed "$PBIS_COMPLETED"); fi

"$HERE/append-sprint-history.sh" "${HIST_ARGS[@]}" >/dev/null

# 2. Clear state.current_sprint_id BEFORE removing sprint.json. state.json's
#    field is defined as "ID of the active Sprint, null if none"; leaving it
#    naming the just-archived Sprint is the drift init-sprint.sh guards against
#    from the other direction. Nulling before the rm is deliberate: on a crash
#    between the two steps a retried run re-enters (sprint.json still present),
#    re-nulls (idempotent), then removes — no window strands a stale pointer.
if [ -f "$STATE" ]; then
  atomic_write "$STATE" ".current_sprint_id = null" "$STATE_SCHEMA"
else
  printf '[rollover-sprint] warning: %s absent; cannot null current_sprint_id\n' \
    "$STATE" >&2
fi

# 3. Clear sprint.json so init-sprint.sh can create the next Sprint. The
#    archive above is the durable record; sprint.json is ephemeral runtime.
rm -f "$SPRINT"

printf '[rollover-sprint] archived %s to sprint-history.json, nulled state.current_sprint_id, and cleared sprint.json\n' \
  "$SPRINT_ID" >&2
printf '%s\n' "$SPRINT_ID"
