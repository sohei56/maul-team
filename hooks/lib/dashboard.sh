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
SESSION_MAP=".scrum/session-map.json"

# ---------------------------------------------------------------------------
# Agent identity (session id → display name)
# ---------------------------------------------------------------------------
# Every hook that names an agent on the dashboard MUST route through these.
# dashboard/app.py colours a row by crc32(agent_id), so a hook that emits a
# raw session UUID renders that teammate in a different colour from its own
# other rows and the operator cannot attribute the event.

# Shorten UUID-style or long-hex agent IDs to first 8 chars for readability.
# This is the form save_session_name uses as the session-map key.
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

# resolve_agent_display_name <session_id>
# Look up the teammate display name in .scrum/session-map.json. Prints the
# name, or NOTHING when the session is unknown — a normal outcome, since only
# sessions that emitted a named event are ever mapped.
# The map is keyed by the SHORTENED id, so all three forms shorten_id can
# produce are probed (the id as given, its first UUID segment, its first 8
# chars). That union lets callers pass either a raw session id or an
# already-shortened one and get the same answer.
resolve_agent_display_name() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  [ -f "$SESSION_MAP" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg sid "$sid" --arg seg "${sid%%-*}" --arg eight "${sid:0:8}" \
    '.[$sid] // .[$seg] // .[$eight] // empty' "$SESSION_MAP" 2>/dev/null || true
}

# resolve_agent_name <session_id>
# As resolve_agent_display_name, but falls back to the id itself when the
# session is unknown. Use this when the caller must render *something*
# (dashboard event rows); use resolve_agent_display_name when an unknown
# session should render as nothing (the attention banner's optional `agent`).
resolve_agent_name() {
  local sid="$1" name
  ensure_scrum_dir
  name="$(resolve_agent_display_name "$sid")"
  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "$sid"
  fi
}

# Save a session-id → teammate-name mapping. Key by the SHORTENED id so
# resolve_agent_display_name's probe forms line up.
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
    # shellcheck disable=SC2016  # $sid/$name are jq variables, not shell expansion.
    json_update_atomic "$SESSION_MAP" '. + {($sid): $name}' \
      --arg sid "$sid" --arg name "$name"
  fi
}

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
