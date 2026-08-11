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
COMMUNICATIONS_FILE=".scrum/communications.json"
PBI_DIR=".scrum/pbi"

# Return the deterministic next orchestration action. Merge handoffs take
# precedence over ordinary pipeline work; a recorded retryable failure routes
# back to a Developer, while the established three-strike ceiling routes to
# escalation. Review and Sprint Review deliberately remain distinct phases.
next_processing_step() {
  local escalated retryable preflight merge_ready id classification state_file
  if [ "$backlog_valid" != "true" ]; then
    printf 'SM requests a bounded Scrum Explorer backlog preflight; backlog.json is missing or malformed, so do not continue or merge.'
    return
  fi

  escalated="$(jq -r '[.items[]? | select(.status == "escalated") | .id] | sort | first // empty' "$BACKLOG_FILE" 2>/dev/null || true)"
  if [ -n "$escalated" ]; then
    printf 'SM handles escalation for %s.' "$escalated"
    return
  fi

  retryable=""
  preflight=""
  merge_ready=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state_file="$PBI_DIR/$id/state.json"
    classification="$(jq -er --arg id "$id" '
      if type != "object" or .pbi_id != $id then "preflight"
      elif (.merge_failure_count | type) != "number"
        or .merge_failure_count < 0
        or (.merge_failure_count | floor) != .merge_failure_count then "preflight"
      elif .merge_failure_count >= 3 then "escalate"
      elif .merge_failure_count >= 1 and .merge_failure_count <= 2 then
        if has("merge_failure") and (.merge_failure | type) == "object"
        then "retry" else "preflight" end
      elif .merge_failure_count == 0 then
        if has("merge_failure") then "preflight"
        elif (.head_sha | type) == "string"
          and (.head_sha | test("^[0-9a-f]{7,40}$"))
          and has("ready_at") and (.ready_at | type) == "string"
          and (.ready_at | length) > 0
          and (.paths_touched | type) == "array"
        then "ready" else "preflight" end
      else "preflight"
      end
    ' "$state_file" 2>/dev/null || printf 'preflight')"
    if [ "$classification" = "escalate" ]; then
      printf 'SM escalates %s after the merge retry limit was reached.' "$id"
      return
    elif [ "$classification" = "retry" ]; then
      [ -n "$retryable" ] || retryable="$id"
    elif [ "$classification" = "ready" ]; then
      [ -n "$merge_ready" ] || merge_ready="$id"
    else
      [ -n "$preflight" ] || preflight="$id"
    fi
  done <<EOF
$(jq -r '[.items[]? | select(.status == "in_progress_merge") | .id] | sort[]' "$BACKLOG_FILE" 2>/dev/null || true)
EOF
  if [ -n "$retryable" ]; then
    printf 'SM respawns a Developer for %s to repair the retryable merge failure.' "$retryable"
  elif [ -n "$preflight" ]; then
    printf 'SM runs a bounded Scrum Explorer merge preflight for %s; state is absent or inconsistent, so do not merge.' "$preflight"
  elif [ -n "$merge_ready" ]; then
    printf 'SM merges %s.' "$merge_ready"
  else
    case "$phase" in
      pbi_pipeline_active) printf 'SM continues the active PBI pipeline and waits for its next artifact.' ;;
      review) printf 'SM completes Sprint-end review, then advances to sprint_review.' ;;
      sprint_review) printf 'SM runs the Sprint Review and obtains the separate PO Sprint acceptance verdict.' ;;
      retrospective) printf 'SM runs the Retrospective.' ;;
      integration_sprint) printf 'SM runs Sprint integration tests.' ;;
      uat_release) printf 'SM runs UAT and release processing.' ;;
      complete) printf 'No processing remains; the Scrum workflow is complete.' ;;
      *) printf 'SM continues the workflow for phase %s.' "$phase" ;;
    esac
  fi
}

open_po_decisions() {
  if [ ! -f "$COMMUNICATIONS_FILE" ]; then
    printf 'none recorded'
    return
  fi
  jq -r '
    reduce (.messages[]? | select(.content | test("PO_DECISION_REQUEST|PO_DECISION"))) as $m
      ({};
       ($m.content | capture("^\\[(?<scope>[^]]+)\\]").scope? // "unknown") as $scope
       | ($m.content | capture("(?:^|[[:space:]])kind=(?<kind>[^][,[:space:]]+)").kind? // "unknown") as $kind
       | ($scope + "/" + $kind) as $key
       | if ($m.content | contains("PO_DECISION_REQUEST")) then .[$key] = true
         elif ($m.content | contains("PO_DECISION")) then del(.[$key]) else . end)
    | keys | sort | if length == 0 then "none" else join(", ") end
  ' "$COMMUNICATIONS_FILE" 2>/dev/null || printf 'unknown'
}

# Read the hook payload from stdin to learn which event fired. Claude Code
# honours context returned under hookSpecificOutput.additionalContext only when
# hookEventName is one of the literals its output schema accepts; a bare
# top-level additionalContext key is ignored. Default to SessionStart when the
# payload is absent or unparseable.
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"
HOOK_EVENT="$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"

# `PostCompact` is a real hook EVENT (this script is registered on it by
# setup-user.sh) but is NOT a member of the hookSpecificOutput.hookEventName
# union — verified against the shipped binary: `PostCompact` appears 33 times
# overall yet never adjacent to `hookEventName`, while SessionStart/Stop/
# PreToolUse do. Echoing the received event name back therefore produced
# `hookEventName:"PostCompact"`, which fails the whole-object schema parse and
# silently discards the context. Normalize to the nearest valid literal —
# re-injecting session context is exactly what SessionStart means.
case "$HOOK_EVENT" in
  SessionStart) ;;
  *)            HOOK_EVENT="SessionStart" ;;
esac

# Build an autonomous-mode prologue to splice into additionalContext.
# Returns empty string when not in autonomy mode (human-mode contract: zero
# behaviour change). The prologue makes three things unambiguous to the lead
# session every time it (re)starts:
#   1. No human PO is present — never wait for human input; spawn the
#      product-owner teammate if not already running.
#   2. In-process Teammates do NOT survive session restarts (Agent-tool
#      sub-agents are bound to the parent session). The resume summary tells
#      SM whether Developer restoration or merge handling is needed.
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
  printf '%s' "AUTONOMOUS PO MODE: No human is present. The product-owner teammate is the PO — spawn it first if not running (see scrum-master.md, Product Owner and user interaction). Never wait for human input. In-process teammates do NOT survive session restarts. Apply the documented liveness checks and restore Developers only for the resume summary's Active PBIs; never generically re-spawn one for a Merge-waiting in_progress_merge PBI. Re-spawn the product-owner teammate as well.${iter_line}"
}

# Build context based on available state
if validate_json_file "$STATE_FILE" "phase" 2>/dev/null; then
  phase="$(jq -r '.phase // "unknown"' "$STATE_FILE")"
  sprint_id="$(jq -r '.current_sprint_id // "none"' "$STATE_FILE")"
  backlog_valid="false"
  if [ -f "$BACKLOG_FILE" ] && jq -e 'type == "object" and (.items | type == "array")' "$BACKLOG_FILE" >/dev/null 2>&1; then
    backlog_valid="true"
  fi
  # product_goal SSOT is backlog.json (set by init-backlog.sh
  # --product-goal); state.json's copy is vestigial and always null in
  # wrapper-governed projects.
  product_goal="unknown"
  if [ "$backlog_valid" = "true" ]; then
    product_goal="$(jq -r '.product_goal // "Not yet defined"' "$BACKLOG_FILE" 2>/dev/null || true)"
    [ -n "$product_goal" ] || product_goal="Not yet defined"
  fi

  # Get Sprint Goal if sprint file exists
  sprint_goal="No active Sprint"
  sprint_type="unknown"
  sprint_status="unknown"
  if validate_json_file "$SPRINT_FILE" "goal" 2>/dev/null && [ "$sprint_id" != "none" ] && [ "$sprint_id" != "null" ]; then
    sprint_goal="$(jq -r '.goal // "No goal set"' "$SPRINT_FILE")"
    sprint_type="$(jq -r '.type // "unknown"' "$SPRINT_FILE")"
    sprint_status="$(jq -r '.status // "unknown"' "$SPRINT_FILE")"
  fi

  # Build one compact resume summary. Every field is present so a resumed SM
  # does not need a second discovery turn merely because a collection is empty.
  active_pbis="unknown"
  merge_waiting="unknown"
  escalations="unknown"
  if [ "$backlog_valid" = "true" ]; then
    active_pbis="$(jq -r '[.items[]? | select(.status | startswith("in_progress_")) | select(.status != "in_progress_merge") | "\(.id)(\(.status))"] | sort | if length == 0 then "none" else join(", ") end' "$BACKLOG_FILE" 2>/dev/null || echo unknown)"
    merge_waiting="$(jq -r '[.items[]? | select(.status == "in_progress_merge") | .id] | sort | if length == 0 then "none" else join(", ") end' "$BACKLOG_FILE" 2>/dev/null || echo unknown)"
    escalations="$(jq -r '[.items[]? | select(.status == "escalated") | .id] | sort | if length == 0 then "none" else join(", ") end' "$BACKLOG_FILE" 2>/dev/null || echo unknown)"
  fi
  po_open="$(open_po_decisions)"
  next_step="$(next_processing_step)"
  context="Resume summary. Phase: ${phase}. Product Goal: ${product_goal}. Sprint Goal: ${sprint_goal}. Active PBIs: ${active_pbis}. Merge-waiting: ${merge_waiting}. Escalations: ${escalations}. Open PO decisions: ${po_open}. Next processing step: ${next_step}"
  if [ "$sprint_id" != "none" ] && [ "$sprint_id" != "null" ]; then
    context="${context} Active Sprint: ${sprint_id} (${sprint_type}, ${sprint_status})."
  fi

  # PBI Pipeline awareness: derive active pipelines from backlog.json (the
  # 13-value status SSOT) so spawned sub-agents know which PBI(s) are in
  # flight. Any status starting with `in_progress_` counts as active. Full
  # env propagation (SCRUM_PBI_ID) is not possible via this hook — sub-agent
  # prompts must include the PBI id explicitly.
  # KEEP IN SYNC with hooks/completion-gate.sh and scripts/stall-watchdog.sh —
  # all three filter "in-flight PBI" the same way. `in_progress_merge` is
  # EXCLUDED: it means handoff awaiting SM action, not a running pipeline.
  # Reporting a merge-queued PBI here as an active pipeline is the exact
  # signal that triggers Developer re-spawn (see § Teammate Liveness
  # Protocol), i.e. duplicate work on an already-complete PBI.
  if [ "$phase" = "pbi_pipeline_active" ] && [ "$backlog_valid" = "true" ]; then
    active_pipelines="$(jq -r '[.items[]? | select(.status | startswith("in_progress_")) | select(.status != "in_progress_merge") | .id] | sort | join(", ")' "$BACKLOG_FILE" 2>/dev/null)"
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
