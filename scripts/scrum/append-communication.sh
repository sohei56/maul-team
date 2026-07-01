#!/usr/bin/env bash
# scripts/scrum/append-communication.sh — append one message to .scrum/communications.json.
# Usage: append-communication.sh --from <id> --to <id|null> --kind <type> --content <text> [--role <role>] [--pbi <pbi-id>]
#
# Builds the message JSON via `jq -n` (so quotes/newlines/special chars in
# --content are properly escaped) then hands the resulting array-append jq
# expression to atomic_write, which serialises concurrent writers via a
# directory lock and re-validates the result against the schema.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

FROM=""; TO=""; KIND=""; CONTENT=""; ROLE=""; PBI=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)    FROM="$2"; shift 2 ;;
    --to)      TO="$2"; shift 2 ;;
    --kind)    KIND="$2"; shift 2 ;;
    --content) CONTENT="$2"; shift 2 ;;
    --role)    ROLE="$2"; shift 2 ;;
    --pbi)     PBI="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$FROM" ]    || fail E_INVALID_ARG "--from required"
[ -n "$KIND" ]    || fail E_INVALID_ARG "--kind required"
[ -n "$CONTENT" ] || fail E_INVALID_ARG "--content required"

case "$KIND" in
  file_changed|tool_use|status_transition|subagent_start|subagent_stop|task_completed|teammate_idle|agent_spawn|progress_update|message|report|review|escalation|info) ;;
  *) fail E_INVALID_ARG "bad --kind: $KIND" ;;
esac

if [ -n "$ROLE" ]; then
  case "$ROLE" in
    scrum-master|developer|teammate|sub-agent|coordinator|system) ;;
    *) fail E_INVALID_ARG "bad --role: $ROLE" ;;
  esac
fi

if [ -n "$PBI" ] && [ "$PBI" != "null" ]; then
  assert_pbi_id "$PBI" --pbi
fi

# Build the message JSON via jq -n so that arbitrary --content (quotes,
# backslashes, newlines) is escaped correctly. recipient_id and pbi_id
# default to JSON null; sender_role is omitted entirely if --role is unset.
MSG_JSON="$(
  jq -n \
    --arg ts "$(_iso_utc_now)" \
    --arg sid "$FROM" \
    --arg rid "$TO" \
    --arg type "$KIND" \
    --arg content "$CONTENT" \
    --arg role "$ROLE" \
    --arg pbi "$PBI" \
    '{
      timestamp: $ts,
      sender_id: $sid,
      type: $type,
      content: $content
    }
    + (if $rid == "" or $rid == "null" then {recipient_id: null} else {recipient_id: $rid} end)
    + (if $role == "" then {} else {sender_role: $role} end)
    + (if $pbi == "" or $pbi == "null" then {pbi_id: null} else {pbi_id: $pbi} end)'
)"

# Mirror the hook-side cap-on-append semantics from hooks/lib/validate.sh::
# append_to_json_array. Default cap (200) matches hooks/dashboard-event.sh's
# MAX_MESSAGES so wrapper vs hook entry paths converge on the same retention.
EXPR=".messages = ((.messages // []) + [$MSG_JSON])
      | (.max_messages // 200) as \$cap
      | if (.messages | length) > \$cap
        then .messages = .messages[(.messages | length) - \$cap:]
        else . end"

atomic_write ".scrum/communications.json" "$EXPR" "$ROOT/docs/contracts/scrum-state/communications.schema.json"
