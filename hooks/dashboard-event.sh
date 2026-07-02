#!/usr/bin/env bash
# dashboard-event.sh — PostToolUse/TeammateIdle/Stop/TaskCompleted/SubagentStart/SubagentStop hook
# Feeds the dashboard events log and communications log.
# Reads hook event JSON from stdin (Claude Code hook payload).
# Each happening is appended to exactly one file: work events
# (file changes, lifecycle, task completion) to .scrum/dashboard.json,
# agent messages (SendMessage, spawns, idle progress) to
# .scrum/communications.json. The dashboard's Work Log panel merges
# both chronologically.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"
# shellcheck source=lib/dashboard.sh
. "$HOOK_DIR/lib/dashboard.sh"

COMMS_FILE=".scrum/communications.json"
SESSION_MAP=".scrum/session-map.json"
MAX_MESSAGES=200

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ensure_comms_file() {
  # shellcheck disable=SC2016  # $max is a jq variable, not shell expansion.
  ensure_json_file "$COMMS_FILE" \
    '{"messages": [], "max_messages": $max}' \
    --argjson max "$MAX_MESSAGES"
}

append_comms_message() {
  local message_json="$1"
  ensure_comms_file
  append_to_json_array "$COMMS_FILE" messages "$message_json" max_messages "$MAX_MESSAGES"
}

# Shorten UUID-style or long-hex agent IDs to first 8 chars for readability.
shorten_id() {
  local id="$1"
  if echo "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-'; then
    echo "${id%%-*}"
  elif echo "$id" | grep -qE '^[0-9a-f]{16,}$'; then
    echo "${id:0:8}"
  else
    echo "$id"
  fi
}

# Map a session ID to a friendly developer name via session-map.json
# Returns the friendly name if found, or the original ID otherwise
resolve_agent_name() {
  local sid="$1"
  ensure_scrum_dir
  if [ -f "$SESSION_MAP" ] && command -v jq >/dev/null 2>&1; then
    local name
    name="$(jq -r --arg sid "$sid" '.[$sid] // empty' "$SESSION_MAP" 2>/dev/null)"
    if [ -n "$name" ]; then
      echo "$name"
      return
    fi
  fi
  echo "$sid"
}

# Save a session-id → teammate-name mapping
save_session_name() {
  local sid="$1"
  local name="$2"
  ensure_scrum_dir
  if [ -z "$sid" ] || [ -z "$name" ] || [ "$sid" = "unknown" ] || [ "$name" = "unknown" ]; then
    return
  fi
  if [ ! -f "$SESSION_MAP" ]; then
    jq -n --arg sid "$sid" --arg name "$name" '{($sid): $name}' > "$SESSION_MAP"
  else
    local tmp_file="${SESSION_MAP}.tmp.$$"
    jq --arg sid "$sid" --arg name "$name" '. + {($sid): $name}' "$SESSION_MAP" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$SESSION_MAP"
  fi
}

# Check if the last comms message has the same sender and content (dedup)
is_duplicate_comms() {
  local sender="$1"
  local content="$2"
  if [ ! -f "$COMMS_FILE" ]; then
    return 1
  fi
  local last_sender last_content
  last_sender="$(jq -r '.messages[-1].sender_id // empty' "$COMMS_FILE" 2>/dev/null)"
  last_content="$(jq -r '.messages[-1].content // empty' "$COMMS_FILE" 2>/dev/null)"
  if [ "$last_sender" = "$sender" ] && [ "$last_content" = "$content" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Read hook event JSON from stdin
hook_event="$(cat)"

# Extract common fields
# Claude Code uses "hook_event_name" as the event type field
hook_type="$(echo "$hook_event" | jq -r '.hook_event_name // .hook_type // .type // "unknown"')"
raw_agent_id="$(echo "$hook_event" | jq -r '.agent_id // .session_id // "unknown"')"
# Friendly name carried in the payload itself: teammate_name (TeammateIdle),
# agent_type (SubagentStart/Stop and subagent-context PostToolUse).
payload_name="$(echo "$hook_event" | jq -r '.teammate_name // .teammate_id // .agent_type // .subagent_type // .agent_name // empty')"
timestamp="$(get_timestamp)"

short_id="$(shorten_id "$raw_agent_id")"
if [ -n "$payload_name" ]; then
  # Persist the id → name mapping so later events that only carry the id
  # (Stop, PostToolUse) still resolve to the friendly name.
  agent_id="$payload_name"
  save_session_name "$short_id" "$payload_name"
else
  agent_id="$(resolve_agent_name "$short_id")"
fi

case "$hook_type" in
  PostToolUse|post_tool_use)
    # Extract tool information
    tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"
    tool_input="$(echo "$hook_event" | jq -c '.tool_input // {}')"

    case "$tool_name" in
      Write|Edit|MultiEdit)
        file_path="$(echo "$tool_input" | jq -r '.file_path // empty')"
        if [ -n "$file_path" ]; then
          # Always "modified": this is a PostToolUse hook, so by the time it
          # runs the tool has already completed and the file always exists —
          # a "created" vs "modified" distinction (Cleanup-audit T1-9) is
          # unreachable here.
          change_type="modified"
          detail="${tool_name} on ${file_path}"

          event_json="$(jq -n \
            --arg ts "$timestamp" \
            --arg type "file_changed" \
            --arg agent "$agent_id" \
            --arg fp "$file_path" \
            --arg ct "$change_type" \
            --arg detail "$detail" \
            '{
              "timestamp": $ts,
              "type": $type,
              "agent_id": $agent,
              "file_path": $fp,
              "change_type": $ct,
              "detail": $detail
            }')"

          append_dashboard_event "$event_json"
        fi
        ;;
      Agent)
        # Agent tool use — spawning subagents
        description="$(echo "$tool_input" | jq -r '.description // empty' | head -c 100)"
        if [ -n "$description" ]; then
          message_json="$(jq -n \
            --arg ts "$timestamp" \
            --arg sid "$agent_id" \
            --arg role "coordinator" \
            --arg type "agent_spawn" \
            --arg content "spawned agent: ${description}" \
            '{
              "timestamp": $ts,
              "sender_id": $sid,
              "sender_role": $role,
              "recipient_id": null,
              "type": $type,
              "content": $content
            }')"
          append_comms_message "$message_json"
        fi
        ;;
      SendMessage)
        # Inter-agent message (e.g. developer → scrum-master / PO).
        recipient="$(echo "$tool_input" | jq -r '.to // empty')"
        content="$(echo "$tool_input" | jq -r '
          (.summary // "") as $s
          | (.message // "") as $m
          | if $s != "" then $s
            elif ($m | type) == "string" then $m
            elif ($m | type) == "object" then ($m.type // "")
            else "" end
        ' | head -c 300)"
        if [ -n "$recipient" ] && [ -n "$content" ]; then
          message_json="$(jq -n \
            --arg ts "$timestamp" \
            --arg sid "$agent_id" \
            --arg rid "$recipient" \
            --arg content "$content" \
            '{
              "timestamp": $ts,
              "sender_id": $sid,
              "recipient_id": $rid,
              "type": "message",
              "content": $content
            }')"
          append_comms_message "$message_json"
        fi
        ;;
    esac
    ;;

  TeammateIdle|teammate_idle)
    # Common extraction above already resolved teammate_name (and saved the
    # session → name mapping for future PostToolUse/Stop lookups).
    sender_id="$agent_id"
    sender_role="teammate"
    # Try multiple fields for content
    content="$(echo "$hook_event" | jq -r '
      (.last_message // .last_assistant_message // .reason // null)
      | if . == null or . == "" then "waiting for task" else . end
    ' | head -c 300)"

    # Skip duplicate "waiting for task" messages from same sender
    if ! is_duplicate_comms "$sender_id" "$content"; then
      message_json="$(jq -n \
        --arg ts "$timestamp" \
        --arg sid "$sender_id" \
        --arg role "$sender_role" \
        --arg type "progress_update" \
        --arg content "$content" \
        '{
          "timestamp": $ts,
          "sender_id": $sid,
          "sender_role": $role,
          "recipient_id": null,
          "type": $type,
          "content": $content
        }')"

      append_comms_message "$message_json"
    fi
    ;;

  Stop|stop)
    # Session or teammate stopping. agent_id resolves to a friendly name
    # only if an earlier event saved a session-map entry for this session.
    reason="$(echo "$hook_event" | jq -r '.reason // "completed"')"
    detail="session stopped (${reason})"

    event_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg agent "$agent_id" \
      --arg detail "$detail" \
      '{
        "timestamp": $ts,
        "type": "status_transition",
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail
      }')"

    append_dashboard_event "$event_json"
    ;;

  SubagentStart|subagent_start)
    # Teammate/subagent starting work. The agent name (payload agent_type)
    # is already in agent_id — detail carries only the action.
    pbi_id="${SCRUM_PBI_ID:-$(echo "$hook_event" | jq -r '.scrum_pbi_id // empty')}"
    detail="started work${pbi_id:+ on ${pbi_id}}"

    event_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg agent "$agent_id" \
      --arg detail "$detail" \
      --arg pbi "$pbi_id" \
      '{
        "timestamp": $ts,
        "type": "subagent_start",
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail,
        "pbi_id": (if $pbi == "" then null else $pbi end)
      }')"

    append_dashboard_event "$event_json"
    ;;

  SubagentStop|subagent_stop)
    # Teammate/subagent finished its work. Name lives in agent_id.
    pbi_id="${SCRUM_PBI_ID:-$(echo "$hook_event" | jq -r '.scrum_pbi_id // empty')}"
    detail="finished work${pbi_id:+ on ${pbi_id}}"

    event_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg agent "$agent_id" \
      --arg detail "$detail" \
      --arg pbi "$pbi_id" \
      '{
        "timestamp": $ts,
        "type": "subagent_stop",
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail,
        "pbi_id": (if $pbi == "" then null else $pbi end)
      }')"

    # The comms "finished work" mirror was removed when the dashboard
    # merged its log panes; completion-gate.sh counts in-flight subagents
    # from these dashboard subagent_start/stop events, so they must stay.
    append_dashboard_event "$event_json"
    ;;

  TaskCompleted|task_completed)
    # A task has been completed
    tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"
    detail="completed task${tool_name:+: ${tool_name}}"

    event_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg agent "$agent_id" \
      --arg detail "$detail" \
      '{
        "timestamp": $ts,
        "type": "task_completed",
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail
      }')"

    append_dashboard_event "$event_json"
    ;;
esac

exit 0
