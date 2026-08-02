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
# shellcheck source=lib/autonomy.sh
. "$HOOK_DIR/lib/autonomy.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

hook_event="$(read_hook_payload)"
[ -n "$hook_event" ] || exit 0

reason="$(payload_get "$hook_event" '.reason')"
[ -n "$reason" ] || reason="unknown"
raw_agent_id="$(payload_get "$hook_event" '.agent_id // .session_id')"
[ -n "$raw_agent_id" ] || raw_agent_id="unknown"
# Normalize exactly as dashboard-event.sh does (shorten, then session-map
# lookup). Emitting the raw session UUID here would colour this row by a
# different crc32 than the same teammate's other rows (dashboard/app.py
# ::_agent_color), leaving the failure unattributable.
agent_id="$(resolve_agent_name "$(shorten_id "$raw_agent_id")")"
timestamp="$(get_timestamp)"

log_hook "stop-failure" "ERROR" "Session failed: $reason (agent: $agent_id)"

append_dashboard_status_event "$timestamp" "stop_failure" "$agent_id" "Session failed: ${reason}"

# Autonomous mode: also persist the failure on .scrum/autonomy.json so the
# watchdog can read last_failure and decide whether to retry / abort the
# outer loop. Fail-open: any error reading/writing autonomy.json is silently
# ignored — the dashboard event above is the authoritative log.
if autonomy_enabled; then
  autonomy_record_failure "$reason" "$timestamp" || true
fi

exit 0
