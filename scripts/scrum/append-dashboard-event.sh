#!/usr/bin/env bash
# scripts/scrum/append-dashboard-event.sh — append one event to .scrum/dashboard.json.events.
# Usage: append-dashboard-event.sh --type <type> [--agent <id>] [--pbi <pbi-id>] [--file <path>]
#                                  [--change-type <ct>] [--detail <text>] [--status-from <s>] [--status-to <s>]
#
# The wrapper does NOT touch `pbi_pipelines[]` (managed by hooks/dashboard-event.sh).
# atomic_write serialises concurrent writers via mkdir lock and re-validates the
# result against the schema.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

TYPE=""; AGENT=""; PBI=""; FILE=""; CHANGE=""; DETAIL=""; STATUS_FROM=""; STATUS_TO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)        TYPE="$2"; shift 2 ;;
    --agent)       AGENT="$2"; shift 2 ;;
    --pbi)         PBI="$2"; shift 2 ;;
    --file)        FILE="$2"; shift 2 ;;
    --change-type) CHANGE="$2"; shift 2 ;;
    --detail)      DETAIL="$2"; shift 2 ;;
    --status-from) STATUS_FROM="$2"; shift 2 ;;
    --status-to)   STATUS_TO="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$TYPE" ] || fail E_INVALID_ARG "--type required"
case "$TYPE" in
  file_changed|tool_use|status_transition|subagent_start|subagent_stop|task_completed|teammate_idle|test_run|review_verdict) ;;
  *) fail E_INVALID_ARG "bad --type: $TYPE" ;;
esac

if [ -n "$PBI" ] && [ "$PBI" != "null" ]; then
  case "$PBI" in
    pbi-[0-9]*) ;;
    *) fail E_INVALID_ARG "bad --pbi: $PBI" ;;
  esac
fi

# Build the event JSON via jq -n. The `or_null` helper consolidates the
# empty-string-or-literal-"null" → JSON null pattern into one place per field.
EVT_JSON="$(
  jq -n \
    --arg ts "$(_iso_utc_now)" \
    --arg type "$TYPE" \
    --arg agent "$AGENT" \
    --arg pbi "$PBI" \
    --arg file "$FILE" \
    --arg change "$CHANGE" \
    --arg detail "$DETAIL" \
    --arg sfrom "$STATUS_FROM" \
    --arg sto "$STATUS_TO" \
    '
    def or_null($s): if $s == "" or $s == "null" then null else $s end;
    {
      timestamp: $ts,
      type: $type,
      agent_id: or_null($agent),
      pbi_id: or_null($pbi),
      file_path: or_null($file),
      change_type: or_null($change),
      detail: or_null($detail),
      status_from: or_null($sfrom),
      status_to: or_null($sto)
    }'
)"

EXPR=".events += [$EVT_JSON]"

atomic_write ".scrum/dashboard.json" "$EXPR" "$ROOT/docs/contracts/scrum-state/dashboard.schema.json"
