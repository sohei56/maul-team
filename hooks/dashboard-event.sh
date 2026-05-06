#!/usr/bin/env bash
# dashboard-event.sh — PostToolUse/TeammateIdle/Stop/TaskCompleted/SubagentStart/SubagentStop hook
# Feeds the dashboard events log and communications log.
# Reads hook event JSON from stdin (Claude Code hook payload).
# Appends file change events to .scrum/dashboard.json and agent
# communication messages to .scrum/communications.json.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

DASHBOARD_FILE=".scrum/dashboard.json"
COMMS_FILE=".scrum/communications.json"
SESSION_MAP=".scrum/session-map.json"
MAX_EVENTS=100
MAX_MESSAGES=200

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ensure_dashboard_file() {
  # shellcheck disable=SC2016  # $max is a jq variable, not shell expansion.
  ensure_json_file "$DASHBOARD_FILE" \
    '{"events": [], "max_events": $max}' \
    --argjson max "$MAX_EVENTS"
}

ensure_comms_file() {
  # shellcheck disable=SC2016  # $max is a jq variable, not shell expansion.
  ensure_json_file "$COMMS_FILE" \
    '{"messages": [], "max_messages": $max}' \
    --argjson max "$MAX_MESSAGES"
}

append_dashboard_event() {
  local event_json="$1"
  ensure_dashboard_file
  append_to_json_array "$DASHBOARD_FILE" events "$event_json" max_events "$MAX_EVENTS"
}

append_comms_message() {
  local message_json="$1"
  ensure_comms_file
  append_to_json_array "$COMMS_FILE" messages "$message_json" max_messages "$MAX_MESSAGES"
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

# Check whether an agent name is one of the PBI Pipeline sub-agents.
is_pbi_pipeline_agent() {
  case "$1" in
    pbi-designer|pbi-implementer|pbi-ut-author) return 0 ;;
    codex-design-reviewer|codex-impl-reviewer|codex-ut-reviewer) return 0 ;;
    *) return 1 ;;
  esac
}

# Update .scrum/dashboard.json.pbi_pipelines for the given PBI id.
# Replaces (or inserts) the entry for the PBI with current status/round/agents.
# event_type: "start" | "stop"
# PBI status is read from backlog.json (12-value SSOT) — pbi-state.json no
# longer carries phase after the status/phase unification.
#
# This hook runs in PreToolUse-handler context, which is itself the guard
# layer — there is no user-facing wrapper for the dashboard `pbi_pipelines`
# projection (it is a derived view, refreshed on every PostToolUse). Raw jq
# is the documented mechanism for hook-side dashboard maintenance; user-
# facing writers must still go through .scrum/scripts/* wrappers. See
# docs/MIGRATION-scrum-state-tools.md "Known gaps" #4.
update_pbi_pipelines() {
  local pbi_id="$1" agent_name="$2" event_type="$3"
  [ -z "$pbi_id" ] && return 0
  ensure_dashboard_file
  local now; now="$(get_timestamp)"
  local sprint_file=".scrum/sprint.json"
  local backlog_file=".scrum/backlog.json"

  local dev="unknown"
  if [ -f "$sprint_file" ]; then
    dev="$(jq -r --arg id "$pbi_id" '.developers[]? | select(.current_pbi == $id) | .id // empty' "$sprint_file" 2>/dev/null)"
    [ -z "$dev" ] && dev="unknown"
  fi

  local pbi_status round
  if [ -f "$backlog_file" ]; then
    pbi_status="$(jq -r --arg id "$pbi_id" '.items[]? | select(.id == $id) | .status // "unknown"' "$backlog_file" 2>/dev/null)"
    [ -z "$pbi_status" ] && pbi_status="unknown"
  else
    pbi_status="unknown"
  fi
  if [ "$pbi_status" = "in_progress_design" ]; then
    round="$(get_pbi_pipeline_state "$pbi_id" design_round 0)"
  else
    round="$(get_pbi_pipeline_state "$pbi_id" impl_round 0)"
  fi

  local tmp="${DASHBOARD_FILE}.tmp.$$"
  jq --arg id "$pbi_id" --arg dev "$dev" --arg pbi_status "$pbi_status" \
     --argjson round "$round" --arg now "$now" --arg agent "$agent_name" \
     --arg ev "$event_type" '
    .pbi_pipelines = (.pbi_pipelines // []) |
    .pbi_pipelines |= map(select(.pbi_id != $id)) |
    .pbi_pipelines += [{
      pbi_id: $id,
      developer: $dev,
      status: $pbi_status,
      round: $round,
      active_subagents: (if $ev == "start" then [$agent] else [] end),
      last_event_at: $now
    }]
  ' "$DASHBOARD_FILE" > "$tmp" && mv "$tmp" "$DASHBOARD_FILE"
}

# Determine the change type for a file operation
determine_change_type() {
  local tool_name="$1"
  local file_path="$2"

  case "$tool_name" in
    Write)
      if [ -f "$file_path" ]; then
        echo "modified"
      else
        echo "created"
      fi
      ;;
    Edit)
      echo "modified"
      ;;
    Bash)
      # Cannot reliably determine — default to modified
      echo "modified"
      ;;
    *)
      echo "modified"
      ;;
  esac
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
timestamp="$(get_timestamp)"

# Shorten UUID-style agent IDs to first 8 chars for readability
shorten_id() {
  local id="$1"
  if echo "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-'; then
    echo "${id%%-*}"
  else
    echo "$id"
  fi
}
short_id="$(shorten_id "$raw_agent_id")"
# Resolve to friendly developer name if a mapping exists
agent_id="$(resolve_agent_name "$short_id")"

case "$hook_type" in
  PostToolUse|post_tool_use)
    # Extract tool information
    tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"
    tool_input="$(echo "$hook_event" | jq -c '.tool_input // {}')"

    case "$tool_name" in
      Write|Edit)
        file_path="$(echo "$tool_input" | jq -r '.file_path // empty')"
        if [ -n "$file_path" ]; then
          change_type="$(determine_change_type "$tool_name" "$file_path")"
          # Use basename for concise display
          short_path="$(basename "$file_path")"
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

          # Also emit a communication message for file changes
          comms_content="${change_type} ${short_path}"
          if ! is_duplicate_comms "$agent_id" "$comms_content"; then
            message_json="$(jq -n \
              --arg ts "$timestamp" \
              --arg sid "$agent_id" \
              --arg role "developer" \
              --arg type "file_change" \
              --arg content "$comms_content" \
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
        fi
        ;;
      Bash)
        # For Bash tool, extract a summary but do not try to determine file paths
        command="$(echo "$tool_input" | jq -r '.command // empty' | head -c 200)"
        if [ -n "$command" ]; then
          detail="Bash: ${command}"

          event_json="$(jq -n \
            --arg ts "$timestamp" \
            --arg type "file_changed" \
            --arg agent "$agent_id" \
            --arg detail "$detail" \
            '{
              "timestamp": $ts,
              "type": $type,
              "agent_id": $agent,
              "file_path": null,
              "change_type": null,
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
    esac
    ;;

  TeammateIdle|teammate_idle)
    # Claude Code provides teammate_name in TeammateIdle payloads
    teammate_name="$(echo "$hook_event" | jq -r '.teammate_name // empty')"
    session_id="$(echo "$hook_event" | jq -r '.session_id // empty')"

    # Build sender_id: prefer teammate_name, fallback to session_id
    if [ -n "$teammate_name" ]; then
      sender_id="$teammate_name"
      # Save session → name mapping for future PostToolUse lookups
      if [ -n "$session_id" ]; then
        save_session_name "$(shorten_id "$session_id")" "$teammate_name"
      fi
    else
      sender_id="$(shorten_id "${session_id:-teammate}")"
    fi

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

    # Also add a dashboard event for teammate idle
    event_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg agent "$sender_id" \
      --arg detail "Teammate idle: ${content}" \
      '{
        "timestamp": $ts,
        "type": "teammate_idle",
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail
      }')"

    append_dashboard_event "$event_json"
    ;;

  Stop|stop)
    # Session or teammate stopping
    reason="$(echo "$hook_event" | jq -r '.reason // "completed"')"
    detail="Session stopped: ${reason}"

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
    # Teammate/subagent starting work
    subagent_name="$(echo "$hook_event" | jq -r '.subagent_type // .agent_name // empty')"
    pbi_id="${SCRUM_PBI_ID:-$(echo "$hook_event" | jq -r '.scrum_pbi_id // empty')}"
    detail="Subagent started${subagent_name:+: ${subagent_name}}${pbi_id:+ for ${pbi_id}}"

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

    if [ -n "$subagent_name" ] && is_pbi_pipeline_agent "$subagent_name" && [ -n "$pbi_id" ]; then
      update_pbi_pipelines "$pbi_id" "$subagent_name" "start"
    fi
    ;;

  SubagentStop|subagent_stop)
    # Teammate finished its work
    subagent_name="$(echo "$hook_event" | jq -r '.subagent_type // .agent_name // empty')"
    pbi_id="${SCRUM_PBI_ID:-$(echo "$hook_event" | jq -r '.scrum_pbi_id // empty')}"
    detail="Teammate finished${subagent_name:+: ${subagent_name}}${pbi_id:+ for ${pbi_id}}"

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

    append_dashboard_event "$event_json"

    if [ -n "$subagent_name" ] && is_pbi_pipeline_agent "$subagent_name" && [ -n "$pbi_id" ]; then
      update_pbi_pipelines "$pbi_id" "$subagent_name" "stop"
    fi

    # Also emit a communication message
    message_json="$(jq -n \
      --arg ts "$timestamp" \
      --arg sid "$agent_id" \
      --arg role "teammate" \
      --arg type "status_change" \
      --arg content "finished work" \
      '{
        "timestamp": $ts,
        "sender_id": $sid,
        "sender_role": $role,
        "recipient_id": null,
        "type": $type,
        "content": $content
      }')"
    append_comms_message "$message_json"
    ;;

  TaskCompleted|task_completed)
    # A task has been completed
    tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"
    detail="Task completed${tool_name:+: ${tool_name}}"

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

  *)
    # Other hook types — emit as status_transition (closest valid schema type)
    tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"
    reason="$(echo "$hook_event" | jq -r '.reason // empty')"
    user_prompt="$(echo "$hook_event" | jq -r '.user_prompt // empty' | head -c 100)"

    if [ -n "$tool_name" ]; then
      detail="Tool: ${tool_name}"
    elif [ -n "$user_prompt" ]; then
      detail="User: ${user_prompt}"
    elif [ -n "$reason" ]; then
      detail="Event (${hook_type}): ${reason}"
    else
      detail="Event: ${hook_type}"
    fi

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
esac

exit 0
