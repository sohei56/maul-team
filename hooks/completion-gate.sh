#!/usr/bin/env bash
# completion-gate.sh — Stop hook
# Verifies exit criteria before allowing a session to complete.
# Reads .scrum/state.json and relevant state files for the current phase.
# Outputs exit code 0 (allow stop) or exit code 2 with reason JSON to stderr
# if exit criteria are not met.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

STATE_FILE=".scrum/state.json"
SPRINT_FILE=".scrum/sprint.json"
BACKLOG_FILE=".scrum/backlog.json"
HISTORY_FILE=".scrum/sprint-history.json"
IMPROVEMENTS_FILE=".scrum/improvements.json"
TEST_RESULTS_FILE=".scrum/test-results.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

block_stop() {
  local reason="$1"
  log_hook "completion-gate" "WARN" "Blocked stop: $reason"
  jq -n --arg r "$reason" '{"reason": $r}' >&2
  exit 2
}

allow_stop() {
  exit 0
}

# Get PBI IDs for the current Sprint
get_sprint_pbi_ids() {
  if [ ! -f "$SPRINT_FILE" ]; then
    echo ""
    return
  fi
  jq -r '.pbi_ids[]? // empty' "$SPRINT_FILE" 2>/dev/null
}

# Get the status of a PBI by its ID from the backlog (thin wrapper around
# the canonical helper in hooks/lib/validate.sh).
get_pbi_status() {
  get_pbi_status_from_backlog "$1" "$BACKLOG_FILE" "unknown"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# If state file does not exist or is invalid, allow stop (nothing to gate)
if ! validate_json_file "$STATE_FILE" "phase"; then
  allow_stop
fi

phase="$(jq -r '.phase // "unknown"' "$STATE_FILE")"
current_sprint_id="$(jq -r '.current_sprint_id // "none"' "$STATE_FILE")"

case "$phase" in
  review)
    # All Sprint PBIs must have status "done"
    if [ ! -f "$SPRINT_FILE" ] || [ ! -f "$BACKLOG_FILE" ]; then
      # Allow stop when state files are missing — blocking would trap users
      stderr_log "completion-gate" "WARNING" "sprint.json or backlog.json missing; cannot verify PBI status."
      allow_stop
    fi

    incomplete_pbis=""
    while IFS= read -r pbi_id; do
      [ -z "$pbi_id" ] && continue
      status="$(get_pbi_status "$pbi_id")"
      if [ "$status" != "done" ]; then
        incomplete_pbis="${incomplete_pbis}${incomplete_pbis:+, }${pbi_id} (status: ${status})"
      fi
    done <<EOF
$(get_sprint_pbi_ids)
EOF

    if [ -n "$incomplete_pbis" ]; then
      block_stop "Review phase: the following Sprint PBIs are not done: ${incomplete_pbis}. All PBIs must be 'done' before stopping."
    fi

    allow_stop
    ;;

  sprint_review)
    # sprint-history.json must have entry for current sprint
    if [ "$current_sprint_id" = "none" ] || [ "$current_sprint_id" = "null" ]; then
      block_stop "Sprint review phase: no current Sprint ID in state.json."
    fi

    if [ ! -f "$HISTORY_FILE" ]; then
      block_stop "Sprint review phase: sprint-history.json does not exist. A Sprint summary must be recorded before stopping."
    fi

    has_entry="$(jq --arg sid "$current_sprint_id" '[.sprints[]? | select(.id == $sid)] | length' "$HISTORY_FILE" 2>/dev/null || echo "0")"

    if [ "$has_entry" = "0" ]; then
      block_stop "Sprint review phase: no entry found for Sprint '${current_sprint_id}' in sprint-history.json. Record the Sprint summary before stopping."
    fi

    allow_stop
    ;;

  retrospective)
    # improvements.json must have entry for current sprint
    if [ "$current_sprint_id" = "none" ] || [ "$current_sprint_id" = "null" ]; then
      block_stop "Retrospective phase: no current Sprint ID in state.json."
    fi

    if [ ! -f "$IMPROVEMENTS_FILE" ]; then
      block_stop "Retrospective phase: improvements.json does not exist. Record improvement items before stopping."
    fi

    has_entry="$(jq --arg sid "$current_sprint_id" '[.entries[]? | select(.sprint_id == $sid)] | length' "$IMPROVEMENTS_FILE" 2>/dev/null || echo "0")"

    if [ "$has_entry" = "0" ]; then
      block_stop "Retrospective phase: no improvement entries found for Sprint '${current_sprint_id}' in improvements.json. Record at least one improvement before stopping."
    fi

    allow_stop
    ;;

  integration_sprint)
    # test-results.json must exist with overall_status: "passed" or "passed_with_skips"
    if [ ! -f "$TEST_RESULTS_FILE" ]; then
      block_stop "Integration Sprint: .scrum/test-results.json does not exist. Run the smoke-test skill before stopping."
    fi

    overall_status="$(jq -r '.overall_status // "unknown"' "$TEST_RESULTS_FILE" 2>/dev/null || echo "unknown")"

    case "$overall_status" in
      passed|passed_with_skips)
        allow_stop
        ;;
      failed)
        # Show which categories failed
        failed_cats="$(jq -r '[.categories[]? | select(.status == "failed") | .name] | join(", ")' "$TEST_RESULTS_FILE" 2>/dev/null || echo "unknown")"
        block_stop "Integration Sprint: automated tests failed. Failed categories: ${failed_cats}. Fix failures and re-run smoke-test before stopping."
        ;;
      pending|running)
        block_stop "Integration Sprint: automated tests are still ${overall_status}. Wait for smoke-test to complete before stopping."
        ;;
      *)
        block_stop "Integration Sprint: test-results.json has unexpected overall_status '${overall_status}'. Expected 'passed' or 'passed_with_skips'."
        ;;
    esac
    ;;

  pbi_pipeline_active)
    # All active PBI pipelines must be terminal (done) or escalated.
    # Escalated PBIs additionally require a recorded resolution.
    # Status is read from backlog.json (12-value SSOT) — pbi-state.json no
    # longer carries phase after the status/phase unification.
    active_pipelines="$(jq -r '.active_pbi_pipelines[]?' "$STATE_FILE" 2>/dev/null)"
    blocked_pipelines=""
    while IFS= read -r pbi_id; do
      [ -z "$pbi_id" ] && continue
      pbi_status="$(get_pbi_status "$pbi_id")"
      case "$pbi_status" in
        done|awaiting_cross_review|cross_review) ;;
        escalated)
          if [ ! -f ".scrum/pbi/$pbi_id/escalation-resolution.md" ]; then
            blocked_pipelines="${blocked_pipelines}${blocked_pipelines:+, }${pbi_id} (escalated, no resolution)"
          fi
          ;;
        *)
          blocked_pipelines="${blocked_pipelines}${blocked_pipelines:+, }${pbi_id} (status: ${pbi_status})"
          ;;
      esac
    done <<EOF
$active_pipelines
EOF

    if [ -n "$blocked_pipelines" ]; then
      block_stop "PBI Pipeline phase: pipelines incomplete or unresolved: ${blocked_pipelines}. All PBI pipelines must be 'done' / 'awaiting_cross_review' / 'cross_review' or 'escalated' (with resolution recorded) before stopping."
    fi
    allow_stop
    ;;

  *)
    # Other phases: allow stop
    allow_stop
    ;;
esac
