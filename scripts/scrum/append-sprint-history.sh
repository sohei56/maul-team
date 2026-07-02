#!/usr/bin/env bash
# scripts/scrum/append-sprint-history.sh — append one SprintSummary to
# .scrum/sprint-history.json.
#
# Usage:
#   append-sprint-history.sh \
#     --id <sprint-id> \
#     --goal <text> \
#     [--type <development|integration>] \
#     [--pbis-completed <int>] \
#     [--pbis-total <int>] \
#     [--started-at <iso8601>] \
#     [--completed-at <iso8601>]   # defaults to now (UTC)
#
# The Sprint history is append-only: existing entries are never rewritten.
# The wrapper is idempotent on `--id` — if a summary for that Sprint already
# exists it is left untouched and the call succeeds (exit 0) with a no-op note
# on stderr. This keeps a retried sprint-review (e.g. after a Stop-gate block)
# from either duplicating an entry — which would corrupt watchdog max_sprints
# accounting — or failing the retry.
#
# Schema: docs/contracts/scrum-state/sprint-history.schema.json.
#
# The store file is created on first call (initial content `{"sprints": []}`)
# and the parent directory `.scrum/` is created automatically.
#
# Echoes the Sprint id on stdout for callers that need to reference it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

ID=""
GOAL=""
TYPE=""
PBIS_COMPLETED=""
PBIS_TOTAL=""
STARTED_AT=""
COMPLETED_AT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id)              ID="$2"; shift 2 ;;
    --goal)            GOAL="$2"; shift 2 ;;
    --type)            TYPE="$2"; shift 2 ;;
    --pbis-completed)  PBIS_COMPLETED="$2"; shift 2 ;;
    --pbis-total)      PBIS_TOTAL="$2"; shift 2 ;;
    --started-at)      STARTED_AT="$2"; shift 2 ;;
    --completed-at)    COMPLETED_AT="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$ID" ]   || fail E_INVALID_ARG "--id required"
[ -n "$GOAL" ] || fail E_INVALID_ARG "--goal required"

assert_sprint_id "$ID" --id

if [ -n "$TYPE" ]; then
  case "$TYPE" in
    development|integration) ;;
    *) fail E_INVALID_ARG "bad --type: $TYPE (expected development|integration)" ;;
  esac
fi

if [ -n "$PBIS_COMPLETED" ]; then
  case "$PBIS_COMPLETED" in
    *[!0-9]*|'') fail E_INVALID_ARG "bad --pbis-completed: $PBIS_COMPLETED (expected non-negative integer)" ;;
  esac
fi

if [ -n "$PBIS_TOTAL" ]; then
  case "$PBIS_TOTAL" in
    *[!0-9]*|'') fail E_INVALID_ARG "bad --pbis-total: $PBIS_TOTAL (expected non-negative integer)" ;;
  esac
fi

PATHF=".scrum/sprint-history.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/sprint-history.schema.json"
mkdir -p "$(dirname "$PATHF")"
if [ ! -f "$PATHF" ]; then
  printf '%s\n' '{"sprints": []}' > "$PATHF"
fi

# Idempotency: a summary for this Sprint already recorded → no-op success.
if jq -e --arg id "$ID" '(.sprints // []) | any(.id == $id)' "$PATHF" >/dev/null 2>&1; then
  printf '[scrum-tool] sprint %s already in history; no-op\n' "$ID" >&2
  printf '%s\n' "$ID"
  exit 0
fi

[ -n "$COMPLETED_AT" ] || COMPLETED_AT="$(_iso_utc_now)"

# Build record via jq -n so all free-form text is properly escaped. Optional
# fields are omitted (not null) when not supplied, matching the schema.
REC_JSON="$(
  jq -n \
    --arg id "$ID" \
    --arg goal "$GOAL" \
    --arg type "$TYPE" \
    --arg pbis_completed "$PBIS_COMPLETED" \
    --arg pbis_total "$PBIS_TOTAL" \
    --arg started_at "$STARTED_AT" \
    --arg completed_at "$COMPLETED_AT" \
    '{ id: $id, goal: $goal, completed_at: $completed_at }
     + (if $type           == "" then {} else { type: $type } end)
     + (if $pbis_completed == "" then {} else { pbis_completed: ($pbis_completed | tonumber) } end)
     + (if $pbis_total     == "" then {} else { pbis_total: ($pbis_total | tonumber) } end)
     + (if $started_at     == "" then {} else { started_at: $started_at } end)'
)"

EXPR=".sprints += [$REC_JSON]"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

printf '%s\n' "$ID"
