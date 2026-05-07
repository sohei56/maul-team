#!/usr/bin/env bash
# stop-failure.sh — StopFailure hook
# Logs session failure events (rate_limit, authentication_failed, etc.)
# to the dashboard for visibility. Reads hook event JSON from stdin.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"
# shellcheck source=lib/dashboard.sh
. "$HOOK_DIR/lib/dashboard.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

hook_event="$(cat)"

reason="$(echo "$hook_event" | jq -r '.reason // "unknown"')"
agent_id="$(echo "$hook_event" | jq -r '.agent_id // .session_id // "unknown"')"
timestamp="$(get_timestamp)"

log_hook "stop-failure" "ERROR" "Session failed: $reason (agent: $agent_id)"

event_json="$(jq -n \
  --arg ts "$timestamp" \
  --arg agent "$agent_id" \
  --arg reason "$reason" \
  --arg detail "Session failed: ${reason}" \
  '{
    "timestamp": $ts,
    "type": "stop_failure",
    "agent_id": $agent,
    "file_path": null,
    "change_type": null,
    "detail": $detail
  }')"

append_dashboard_event "$event_json"

exit 0
