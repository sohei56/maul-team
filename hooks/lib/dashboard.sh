#!/usr/bin/env bash
# dashboard.sh — Shared dashboard helpers for hooks.
# Sourced by hooks that append events to .scrum/dashboard.json.
# Requires lib/validate.sh sourced first (provides ensure_json_file,
# append_to_json_array).

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_DASHBOARD_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_DASHBOARD_SH_LOADED=1

DASHBOARD_FILE=".scrum/dashboard.json"
DASHBOARD_MAX_EVENTS="${DASHBOARD_MAX_EVENTS:-100}"

# Initialize .scrum/dashboard.json with the canonical empty shape if missing.
ensure_dashboard_file() {
  # shellcheck disable=SC2016  # $max is a jq variable, not shell expansion.
  ensure_json_file "$DASHBOARD_FILE" \
    '{"events": [], "max_events": $max}' \
    --argjson max "$DASHBOARD_MAX_EVENTS"
}

# Append an event JSON object to .events, capped at max_events (newest kept).
# Usage: append_dashboard_event <event_json>
append_dashboard_event() {
  local event_json="$1"
  ensure_dashboard_file
  append_to_json_array "$DASHBOARD_FILE" events "$event_json" max_events "$DASHBOARD_MAX_EVENTS"
}

# append_dashboard_status_event <timestamp> <type> <agent> <detail> [pbi_id]
# Build and append a lifecycle status event with the canonical shape
# {timestamp, type, agent_id, file_path:null, change_type:null, detail}.
# This is the single constructor for the non-file-change dashboard events
# (Stop / SubagentStart / SubagentStop / TaskCompleted / StopFailure);
# callers pass all fields explicitly rather than relying on globals.
# pbi_id is presence-sensitive: when a 5th argument is passed the event
# carries a "pbi_id" key (empty string → JSON null); when omitted, no
# "pbi_id" key is emitted at all (Stop / TaskCompleted / stop_failure
# events never had one).
append_dashboard_status_event() {
  local ts="$1" ev_type="$2" agent="$3" detail="$4"
  local event_json
  # shellcheck disable=SC2016  # $ts/$type/$agent/$detail/$pbi are jq variables.
  if [ "$#" -ge 5 ]; then
    event_json="$(jq -n \
      --arg ts "$ts" \
      --arg type "$ev_type" \
      --arg agent "$agent" \
      --arg detail "$detail" \
      --arg pbi "$5" \
      '{
        "timestamp": $ts,
        "type": $type,
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail,
        "pbi_id": (if $pbi == "" then null else $pbi end)
      }')"
  else
    event_json="$(jq -n \
      --arg ts "$ts" \
      --arg type "$ev_type" \
      --arg agent "$agent" \
      --arg detail "$detail" \
      '{
        "timestamp": $ts,
        "type": $type,
        "agent_id": $agent,
        "file_path": null,
        "change_type": null,
        "detail": $detail
      }')"
  fi
  append_dashboard_event "$event_json"
}
