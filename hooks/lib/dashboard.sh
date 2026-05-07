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
