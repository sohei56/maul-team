#!/usr/bin/env bash
# scripts/scrum/init-sprint.sh — initialise a fresh Sprint at planning start.
# Usage: init-sprint.sh <sprint-id> [--goal <goal>] [--type development|integration]
#
# Creates `.scrum/sprint.json` (status=planning, started_at=now,
# developers=[]) AND updates `.scrum/state.json.current_sprint_id` in the
# same call. Sprint PBI membership is derived from `backlog.json.items[]`
# where `sprint_id == sprint.json.id`; the legacy `pbi_ids` /
# `developer_count` fields were removed (OD-4 single-source). Atomicity within a single Sprint init is the whole point —
# leaving these in sync prevents the recurring class of bug where
# `state.current_sprint_id` lags behind `sprint.id` (caught by completion-gate
# on Stop, see IMP-003/IMP-009/imp-s28-02 in target-project retrospectives).
#
# Refuses if .scrum/sprint.json already exists. Use this script exactly once
# per Sprint, then drive lifecycle via update-sprint-status.sh /
# freeze-sprint-base.sh / set-sprint-developer.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

SPRINT_ID=""
GOAL=""
TYPE="development"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --goal) [ "$#" -ge 2 ] || fail E_INVALID_ARG "--goal needs value"; GOAL="$2"; shift 2 ;;
    --type) [ "$#" -ge 2 ] || fail E_INVALID_ARG "--type needs value"; TYPE="$2"; shift 2 ;;
    -*)     fail E_INVALID_ARG "unknown flag: $1" ;;
    *)
      if [ -z "$SPRINT_ID" ]; then
        SPRINT_ID="$1"; shift
      else
        fail E_INVALID_ARG "unexpected positional: $1"
      fi
      ;;
  esac
done

[ -n "$SPRINT_ID" ] || fail E_INVALID_ARG "usage: init-sprint.sh <sprint-id> [--goal <goal>] [--type development|integration]"
assert_sprint_id "$SPRINT_ID"
case "$TYPE" in development|integration) ;; *) fail E_INVALID_ARG "bad type: $TYPE (expected development|integration)" ;; esac

SPRINT=".scrum/sprint.json"
STATE=".scrum/state.json"
SPRINT_SCHEMA="$ROOT/docs/contracts/scrum-state/sprint.schema.json"
STATE_SCHEMA="$ROOT/docs/contracts/scrum-state/state.schema.json"

[ ! -f "$SPRINT" ] || fail E_INVALID_ARG "$SPRINT already exists — refusing to overwrite"
[ -f "$STATE" ]    || fail E_FILE_MISSING "$STATE"

NOW="$(_iso_utc_now)"

# Build sprint.json. `goal` is null when --goal not supplied; the schema permits
# null/string.
#
# `pbi_ids` and `developer_count` were removed in the OD-4 single-source pass.
# Sprint PBI membership is now derived from
# `backlog.json.items[] | select(.sprint_id == sprint.id) | .id`, and developer
# count from `sprint.json.developers | length`. The schema's
# `additionalProperties: true` means pre-existing files retaining the old
# fields keep validating; we just stop seeding them.
# shellcheck disable=SC2016  # $id/$goal/$type/$now are jq vars, expanded by jq -n --arg
atomic_create "$SPRINT" "$SPRINT_SCHEMA" '{
  id: $id, goal: (if $goal == "" then null else $goal end),
  type: $type, status: "planning",
  developers: [],
  started_at: $now, completed_at: null
}' --arg id "$SPRINT_ID" --arg goal "$GOAL" --arg type "$TYPE" --arg now "$NOW"

# Update state.json.current_sprint_id via the standard atomic_write helper.
# If this second write fails (e.g. schema violation), roll back the sprint.json
# just created so no orphan half-init survives. atomic_write's `fail` exits, so
# run it in a subshell to intercept the nonzero status and clean up first.
if ! ( atomic_write "$STATE" \
         ".current_sprint_id = \"$SPRINT_ID\"" \
         "$STATE_SCHEMA" ); then
  rm -f "$SPRINT"
  fail E_SCHEMA "state.current_sprint_id update failed; rolled back $SPRINT (no orphan sprint.json left)"
fi

printf '[init-sprint] created %s (type=%s) and set state.current_sprint_id=%s\n' \
  "$SPRINT_ID" "$TYPE" "$SPRINT_ID"
