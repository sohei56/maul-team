#!/usr/bin/env bash
# session-context.sh — SessionStart hook
# Reads .scrum/state.json and outputs additionalContext JSON
# with current phase, Sprint ID, Sprint Goal, and resume context.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

STATE_FILE=".scrum/state.json"
SPRINT_FILE=".scrum/sprint.json"
BACKLOG_FILE=".scrum/backlog.json"

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
  # 12-value status SSOT) so spawned sub-agents know which PBI(s) are in
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

  # Output additionalContext JSON
  jq -n \
    --arg context "$context" \
    '{
      "additionalContext": $context
    }'
else
  # New project — no state yet
  jq -n '{
    "additionalContext": "New project. No .scrum/state.json found. Begin by starting a Requirements Sprint to define the Product Goal and gather requirements."
  }'
fi
