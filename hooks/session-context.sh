#!/usr/bin/env bash
# session-context.sh — SessionStart hook
# Reads .scrum/state.json and outputs additionalContext JSON
# with current phase, Sprint ID, Sprint Goal, and resume context.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"
# shellcheck source=lib/autonomy.sh
. "$HOOK_DIR/lib/autonomy.sh"

STATE_FILE=".scrum/state.json"
SPRINT_FILE=".scrum/sprint.json"
BACKLOG_FILE=".scrum/backlog.json"

# Read the hook payload from stdin to learn which event fired. Claude Code only
# honours SessionStart/PostCompact context returned under
# hookSpecificOutput.additionalContext with a matching hookEventName; a bare
# top-level additionalContext key is ignored. Default to SessionStart when the
# payload is absent or unparseable.
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"
HOOK_EVENT="$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
if [ -z "$HOOK_EVENT" ]; then
  HOOK_EVENT="SessionStart"
fi

# Build an autonomous-mode prologue to splice into additionalContext.
# Returns empty string when not in autonomy mode (human-mode contract: zero
# behaviour change). The prologue makes three things unambiguous to the lead
# session every time it (re)starts:
#   1. No human PO is present — never wait for human input; spawn the
#      product-owner teammate if not already running.
#   2. In-process Teammates do NOT survive session restarts (Agent-tool
#      sub-agents are bound to the parent session). Backlog scan tells SM
#      whether re-spawn is needed.
#   3. Iteration N of M is a quick budget reminder.
autonomous_prologue() {
  if ! autonomy_enabled; then
    return 0
  fi
  local iter max
  iter="$(jq -r '.iteration // 0' .scrum/autonomy.json 2>/dev/null || echo 0)"
  max="$(autonomy_config_int '.autonomous.max_iterations' 0)"
  local iter_line=""
  if [ "$max" -gt 0 ]; then
    iter_line=" Autonomous run iteration ${iter} of ${max}."
  else
    iter_line=" Autonomous run iteration ${iter}."
  fi
  printf '%s' "AUTONOMOUS PO MODE: No human is present. The product-owner teammate is the PO — spawn it first if not running (see scrum-master.md § Autonomous PO Mode). Never wait for human input. In-process teammates do NOT survive session restarts. If backlog.json has in_progress_* PBIs, re-spawn Developers per the Teammate Liveness Protocol; re-spawn the product-owner teammate as well.${iter_line}"
}

# Build context based on available state
if validate_json_file "$STATE_FILE" "phase" 2>/dev/null; then
  phase="$(jq -r '.phase // "unknown"' "$STATE_FILE")"
  sprint_id="$(jq -r '.current_sprint_id // "none"' "$STATE_FILE")"
  product_goal="$(jq -r '.product_goal // "Not yet defined"' "$STATE_FILE")"

  # Get Sprint Goal if sprint file exists
  sprint_goal="No active Sprint"
  sprint_type="unknown"
  sprint_status="unknown"
  if validate_json_file "$SPRINT_FILE" "goal" 2>/dev/null && [ "$sprint_id" != "none" ] && [ "$sprint_id" != "null" ]; then
    sprint_goal="$(jq -r '.goal // "No goal set"' "$SPRINT_FILE")"
    sprint_type="$(jq -r '.type // "unknown"' "$SPRINT_FILE")"
    sprint_status="$(jq -r '.status // "unknown"' "$SPRINT_FILE")"
  fi

  # Build resume context
  context="Resuming project. Product Goal: ${product_goal}. Current phase: ${phase}."
  if [ "$sprint_id" != "none" ] && [ "$sprint_id" != "null" ]; then
    context="${context} Active Sprint: ${sprint_id} (${sprint_type}, ${sprint_status}). Sprint Goal: ${sprint_goal}."
  fi

  # PBI Pipeline awareness: derive active pipelines from backlog.json (the
  # 13-value status SSOT) so spawned sub-agents know which PBI(s) are in
  # flight. Any status starting with `in_progress_` counts as active. Full
  # env propagation (SCRUM_PBI_ID) is not possible via this hook — sub-agent
  # prompts must include the PBI id explicitly.
  if [ "$phase" = "pbi_pipeline_active" ] && [ -f "$BACKLOG_FILE" ]; then
    active_pipelines="$(jq -r '[.items[]? | select(.status | startswith("in_progress_")) | .id] | join(", ")' "$BACKLOG_FILE" 2>/dev/null)"
    if [ -n "$active_pipelines" ]; then
      context="${context} Active PBI pipelines: ${active_pipelines}."
    fi
  fi

  log_hook "session-context" "INFO" "Session started in phase: ${phase}"

  prologue="$(autonomous_prologue)"
  if [ -n "$prologue" ]; then
    context="${prologue} ${context}"
  fi

  # Output additionalContext under hookSpecificOutput so Claude Code honours it.
  jq -n \
    --arg event "$HOOK_EVENT" \
    --arg context "$context" \
    '{
      "hookSpecificOutput": {
        "hookEventName": $event,
        "additionalContext": $context
      }
    }'
else
  # New project — no state yet
  base_context="New project. No .scrum/state.json found. Begin by starting a Requirement Definition to define the Product Goal and gather requirements."
  prologue="$(autonomous_prologue)"
  if [ -n "$prologue" ]; then
    base_context="${prologue} ${base_context}"
  fi
  jq -n \
    --arg event "$HOOK_EVENT" \
    --arg context "$base_context" \
    '{"hookSpecificOutput": {"hookEventName": $event, "additionalContext": $context}}'
fi
