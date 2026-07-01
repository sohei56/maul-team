#!/usr/bin/env bash
# completion-gate.sh — Stop hook
# Verifies exit criteria before allowing a session to complete.
# Reads .scrum/state.json and relevant state files for the current phase.
# Returns exit 2 with a JSON reason on stderr to block stop, or exit 0 to
# allow.
#
# Block-noise policy:
#   * Autonomous-PO mode WITH a live watchdog (autonomy_loop_active) — block
#     on every Stop while the condition holds, with the original verbose
#     reason. The watchdog contract depends on this; see
#     autonomous_intercept_or_allow(). If autonomous mode is configured but
#     NO live watchdog is driving the loop (autonomy.json.watchdog_pid is
#     absent/null or its process is dead), the gate degrades to human-mode
#     behaviour so it never storms a session nothing will re-launch.
#   * Human mode — collapse repeated identical blocks via
#     hooks/lib/stop-gate-state.sh (".scrum/stop-gate.json"): first block of
#     a <phase, signature> tuple emits the verbose reason and exits 2;
#     subsequent blocks of the same tuple are logged-only and allow stop.
#     Phase change or signature change resets the ledger.
#   * pbi_pipeline_active in human mode no longer blocks merely on
#     in_flight > 0 — external watchdogs handle teammate liveness. Only
#     `escalated` PBIs without a recorded resolution still block.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"
# shellcheck source=lib/autonomy.sh
. "$HOOK_DIR/lib/autonomy.sh"
# shellcheck source=lib/stop-gate-state.sh
. "$HOOK_DIR/lib/stop-gate-state.sh"

STATE_FILE=".scrum/state.json"
SPRINT_FILE=".scrum/sprint.json"
BACKLOG_FILE=".scrum/backlog.json"
HISTORY_FILE=".scrum/sprint-history.json"
IMPROVEMENTS_FILE=".scrum/improvements.json"
TEST_RESULTS_FILE=".scrum/test-results.json"
DASHBOARD_FILE=".scrum/dashboard.json"

# ---------------------------------------------------------------------------
# stdin payload — read once, never block.
#
# Claude Code passes Stop-hook JSON on stdin (e.g. {"session_id": "...", ...}).
# Existing tests do NOT pipe a payload, so we must accept an empty stdin
# without blocking. `cat` with a closed-pipe stdin returns immediately; if
# stdin is the terminal we would block, which never happens under the harness
# but could happen if a developer runs the hook by hand — short-circuit with
# `-t 0` to detect "no piped input" and fall through.
# ---------------------------------------------------------------------------
STOP_PAYLOAD=""
if [ ! -t 0 ]; then
  STOP_PAYLOAD="$(cat 2>/dev/null || true)"
fi
SESSION_ID=""
if [ -n "$STOP_PAYLOAD" ]; then
  SESSION_ID="$(printf '%s' "$STOP_PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null || echo "")"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# autonomy_breaker_step
# Shared per-phase circuit-breaker bookkeeping for autonomous mode. Bumps the
# stop-block counter for the current $phase and consults
# autonomous.stop_block_budget_per_phase. Echoes exactly one verdict:
#   unavailable    — counter bookkeeping failed (no/invalid autonomy.json)
#   trip           — budget exceeded; the breaker has been recorded, the
#                    caller MUST allow exit so the watchdog flags the run
#   block:<n>/<b>  — within budget; the caller should keep blocking, and
#                    <n>/<b> may be surfaced in the block reason.
# Used by BOTH block_stop (bounded path) and autonomous_intercept_or_allow so
# the two share one terminal contract. The watchdog resets the counter to 0 at
# the start of every iteration, so the budget is per-iteration.
autonomy_breaker_step() {
  local budget new_count
  budget="$(autonomy_config_int '.autonomous.stop_block_budget_per_phase' 8)"
  new_count="$(bump_stop_block_counter "${phase:-unknown}" 2>/dev/null || echo "0")"
  if [ "${new_count:-0}" = "0" ]; then
    printf 'unavailable'
    return 0
  fi
  if [ "$new_count" -gt "$budget" ]; then
    record_circuit_breaker "${phase:-unknown}" || true
    printf 'trip'
    return 0
  fi
  printf 'block:%s/%s' "$new_count" "$budget"
}

block_stop() {
  # Usage: block_stop <reason> <block_kind> <signature> [breaker_mode]
  #   <reason>     human-readable text for the LLM (long-form OK).
  #   <block_kind> short tag (e.g. review_incomplete, sprint_history_missing,
  #               escalated_unresolved, tests_failed). Combined with the
  #               signature to form the dedup fingerprint.
  #   <signature>  state snapshot that identifies the situation — e.g. the
  #               sorted list of incomplete PBI IDs, the current sprint_id.
  #               Empty string is allowed.
  #   breaker_mode (autonomy only) — "bounded" (default) routes the block
  #               through the per-phase circuit breaker so a stuck phase
  #               terminates the iteration instead of pinning the session in
  #               an unbounded hard block; "unbounded" is the healthy
  #               pbi_pipeline_active inner loop (teammates working) that must
  #               keep firing every turn-end without consuming the budget.
  #
  # When the autonomy loop is active (autonomous mode + a live watchdog,
  # i.e. `autonomy_loop_active`), the human-mode dedup ledger is bypassed: the
  # watchdog contract relies on Stop blocks firing while the condition holds.
  # Historically EVERY autonomous block did `exit 2` directly and so never
  # reached the circuit breaker (which lived only on the allow path) — leaving
  # exit-criteria-miss phases (e.g. `review` with an unresolvable escalated
  # PBI) with no terminal, burning iterations/cost. Bounded blocks now consume
  # the same per-phase budget and trip the breaker, which allows exit so the
  # watchdog flags the run. In human mode — and in autonomous mode with no live
  # watchdog — the dedup ledger collapses repeats to logged-only allow_stop.
  local reason="$1"
  local block_kind="${2:-unknown}"
  local signature="${3:-}"
  local breaker_mode="${4:-bounded}"
  local hint
  hint="$(in_flight_hint)"

  if autonomy_loop_active; then
    if [ "$breaker_mode" = "unbounded" ]; then
      log_hook "completion-gate" "WARN" "Blocked stop: $reason"
      jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Reason: ${reason}${hint}" '{"reason": $r}' >&2
      exit 2
    fi
    local bstep
    bstep="$(autonomy_breaker_step)"
    case "$bstep" in
      trip)
        log_hook "completion-gate" "WARN" "Circuit breaker tripped via block_stop in phase '${phase:-unknown}': $reason"
        exit 0
        ;;
      unavailable)
        # Counter bookkeeping unavailable — fail-open to a plain block (do not
        # silently allow an exit-criteria miss). The watchdog's outer
        # max_iterations / wall-clock valves still bound the degenerate case.
        log_hook "completion-gate" "WARN" "Blocked stop (breaker unavailable): $reason"
        jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Reason: ${reason}${hint}" '{"reason": $r}' >&2
        exit 2
        ;;
      *)
        log_hook "completion-gate" "WARN" "Blocked stop (${bstep#block:}): $reason"
        jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Reason: ${reason}${hint} (stop-block ${bstep#block:} for phase '${phase:-unknown}')" '{"reason": $r}' >&2
        exit 2
        ;;
    esac
  fi

  # Human mode (or autonomous mode with no live watchdog): consult the dedup
  # ledger so a session that nothing will re-launch is not blocked forever.
  local fingerprint verdict
  fingerprint="${block_kind}|${signature}"
  verdict="$(stop_gate_check_and_bump "$fingerprint" "${phase:-unknown}" 2>/dev/null || echo "FIRST")"

  case "$verdict" in
    FIRST)
      log_hook "completion-gate" "WARN" "Blocked stop: $reason"
      jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Reason: ${reason}${hint}" '{"reason": $r}' >&2
      exit 2
      ;;
    REPEAT:*)
      local count
      count="${verdict#REPEAT:}"
      log_hook "completion-gate" "INFO" "suppressed repeat block (${fingerprint}, count=${count})"
      exit 0
      ;;
    *)
      # Unknown verdict — fail-open toward block (safer than mute).
      log_hook "completion-gate" "WARN" "Blocked stop: $reason"
      jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Reason: ${reason}${hint}" '{"reason": $r}' >&2
      exit 2
      ;;
  esac
}

# Count in-flight subagents from dashboard.json: agent_ids with a
# subagent_start event and no later subagent_stop event. Echoes the
# count (integer). Fail-open: empty/missing dashboard → 0.
count_in_flight_subagents() {
  if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "0"
    return
  fi
  jq -r '
    [.events[]? | select(.type == "subagent_start" or .type == "subagent_stop")]
    | group_by(.agent_id)
    | map(
        sort_by(.timestamp)
        | last
        | select(.type == "subagent_start")
      )
    | length
  ' "$DASHBOARD_FILE" 2>/dev/null || echo "0"
}

# Append a guidance hint to the block reason when subagents are still
# running. Keeps SM from misreading the block as agent failure and
# re-spawning into a duplicate-work loop (see scrum-master.md
# § Background Subagent + Stop Hook Reading).
in_flight_hint() {
  local n
  n="$(count_in_flight_subagents)"
  if [ "${n:-0}" -gt 0 ]; then
    printf ' [%d subagent(s) still running. WAIT for them to finish — do NOT re-spawn. Use TaskGet to verify status. Re-spawn only if TaskGet shows terminated AND expected output artifact is missing.]' "$n"
  fi
}

allow_stop() {
  # Default exit-criteria path has decided this session is free to stop.
  # In autonomous-PO mode the lead Stop is an internal-loop iteration, not
  # a true completion: we keep the session alive across phases by replacing
  # the allow with a phase-specific "do not stop, do X next" block.
  # Non-autonomous (human) mode falls through immediately — no behaviour
  # change.
  autonomous_intercept_or_allow
  exit 0
}

# ---------------------------------------------------------------------------
# Autonomous-PO interception
# ---------------------------------------------------------------------------
#
# Contract (mirrored in scripts/autonomous/watchdog.sh):
#   * The watchdog drives the outer loop by re-launching `claude -p` whenever
#     the Stop hook *allows* exit. So letting the hook return 0 hands control
#     back to the watchdog (which advances iteration counters, checks the
#     circuit breaker, etc.).
#   * Returning 2 (block) keeps the same in-process session alive and
#     instructs the lead to take the next phase action. This is the "inner
#     loop" — we use it whenever we want the SM to continue work in-process
#     rather than recycle the session.
#   * `bump_stop_block_counter` is incremented per block per phase; once we
#     exceed `autonomous.stop_block_budget_per_phase` (default 8) we trip the
#     circuit breaker and allow exit so the watchdog can flag this run as
#     failed.
#
# Phase decisions:
#   complete                          → allow (watchdog observes terminal)
#   retrospective (criteria passed)   → allow (recycle session for next sprint)
#   integration_sprint (passed)       → allow (recycle session for next loop)
#   backlog_created (Sprint rollover: → allow (recycle session before next
#     sprint-history non-empty)              Sprint Planning)
#   backlog_created (initial backlog) → block + "run sprint-planning"
#   anything else reached via allow_stop → block + "do X next" instruction
#
# Teammate sessions (session_id != lead_session_id) always allow — blocking
# them would just spin idle Agent-tool callers and burn tokens.
autonomous_intercept_or_allow() {
  # Fail-open: any error path here simply allows the original allow_stop.
  # autonomy_loop_active (not autonomy_enabled) gates this: with no live
  # watchdog there is no outer loop to hand control to, so we must allow the
  # stop rather than keep the session pinned with "do X next" blocks.
  if ! autonomy_loop_active; then
    return 0
  fi
  if [ -z "$SESSION_ID" ]; then
    return 0
  fi
  if ! is_lead_session "$SESSION_ID"; then
    return 0
  fi
  # No phase known (state.json missing/invalid) — nothing meaningful to do.
  if [ -z "$phase" ] || [ "$phase" = "unknown" ]; then
    return 0
  fi

  case "$phase" in
    complete|retrospective|integration_sprint)
      # Checkpoint phases — exit criteria has been met; let the watchdog
      # take over the next phase (or terminate on `complete`).
      return 0
      ;;
    backlog_created)
      # A `backlog_created` phase that FOLLOWS at least one completed
      # Sprint is a Sprint rollover produced by the Retrospective's
      # sprint-continuation handshake (retrospective → next_sprint). It
      # is a clean recycle checkpoint: allow the stop so the watchdog
      # spawns a fresh session for the next Sprint's planning. The
      # INITIAL backlog (post-requirements, no Sprint history yet) is NOT
      # a checkpoint — fall through so the SM is blocked to proceed
      # directly into the first Sprint Planning.
      # A single jq read doubles as the validity probe: a missing or
      # malformed file makes jq fail, and `|| echo 0` defaults the count
      # to 0, which falls through to block (the conservative direction).
      local _sprints
      _sprints="$(jq -r '(.sprints // []) | length' \
        ".scrum/sprint-history.json" 2>/dev/null || echo 0)"
      if [ "${_sprints:-0}" -ge 1 ]; then
        return 0
      fi
      ;;
  esac

  # Shared per-phase breaker bookkeeping (see autonomy_breaker_step).
  #   unavailable — counter bookkeeping failed; fail-open allow (we are in
  #     autonomy mode per the config flag but cannot track progress, and
  #     letting the watchdog observe the allow is safer than an infinite block)
  #   trip        — budget exceeded; breaker recorded; allow so the watchdog
  #     flags the run
  local bstep
  bstep="$(autonomy_breaker_step)"
  case "$bstep" in
    unavailable)
      return 0
      ;;
    trip)
      log_hook "completion-gate" "WARN" "Circuit breaker tripped for phase '${phase}'"
      return 0
      ;;
  esac

  local instruction
  instruction="$(autonomous_next_action "$phase")"
  log_hook "completion-gate" "INFO" "Autonomous block in '$phase' (${bstep#block:}): $instruction"
  jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} Autonomous mode (lead session): do NOT stop. ${instruction} (stop-block ${bstep#block:} for phase '${phase}')" \
    '{"reason": $r}' >&2
  exit 2
}

# Phase → next-action instruction for the lead SM. Kept terse so it fits in
# Stop-hook stderr (Claude trims long messages).
autonomous_next_action() {
  case "$1" in
    new)
      printf '%s' "Phase 'new': run the requirement-definition skill to elicit requirements and advance phase to requirements_sprint."
      ;;
    requirements_sprint)
      printf '%s' "Phase 'requirements_sprint': finalize requirements with the product-owner teammate, create the initial backlog, and advance phase to backlog_created."
      ;;
    backlog_created)
      printf '%s' "Phase 'backlog_created': run the sprint-planning skill to plan the next Sprint and advance phase to sprint_planning."
      ;;
    sprint_planning)
      printf '%s' "Phase 'sprint_planning': run spawn-teammates to start Developers on the Sprint, then advance phase to pbi_pipeline_active."
      ;;
    pbi_pipeline_active)
      printf '%s' "Phase 'pbi_pipeline_active': all in-flight PBIs are settled. Advance phase to review."
      ;;
    review)
      printf '%s' "Phase 'review': all PBIs are done. Advance phase to sprint_review and run the sprint-review skill."
      ;;
    sprint_review)
      printf '%s' "Phase 'sprint_review': summary recorded. Advance phase to retrospective and run the retrospective skill."
      ;;
    *)
      printf '%s' "Phase '$1': continue the autonomous workflow per scrum-master.md (Autonomous PO Mode section)."
      ;;
  esac
}

# Get PBI IDs for the current Sprint.
#
# OD-4 (2026-06): the deprecated `sprint.json.pbi_ids` field is no longer
# seeded by `init-sprint.sh`. Derive Sprint membership from
# `backlog.json.items[]` where `sprint_id` matches the supplied Sprint id.
# Pre-existing files that still carry `pbi_ids` revalidate fine
# (`sprint.schema.json` is `additionalProperties: true`) but this gate never
# reads them again.
get_sprint_pbi_ids() {
  local sprint_id="$1"
  if [ -z "$sprint_id" ] || [ "$sprint_id" = "none" ] || [ ! -f "$BACKLOG_FILE" ]; then
    echo ""
    return
  fi
  jq -r --arg sid "$sprint_id" \
    '.items[]? | select(.sprint_id == $sid) | .id // empty' \
    "$BACKLOG_FILE" 2>/dev/null
}

# Get the status of a PBI by its ID from the backlog (thin wrapper around
# the canonical helper in hooks/lib/validate.sh).
get_pbi_status() {
  get_pbi_status_from_backlog "$1" "$BACKLOG_FILE" "unknown"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Initialise phase early so allow_stop → autonomous_intercept_or_allow can
# read it safely under `set -u`, even if state.json is missing/invalid.
phase=""
current_sprint_id="none"

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
$(get_sprint_pbi_ids "$current_sprint_id")
EOF

    if [ -n "$incomplete_pbis" ]; then
      block_stop \
        "Review phase: the following Sprint PBIs are not done: ${incomplete_pbis}. All PBIs must be 'done' before stopping." \
        "review_incomplete" \
        "$incomplete_pbis"
    fi

    allow_stop
    ;;

  sprint_review)
    # sprint-history.json must have entry for current sprint
    if [ "$current_sprint_id" = "none" ] || [ "$current_sprint_id" = "null" ]; then
      block_stop \
        "Sprint review phase: no current Sprint ID in state.json." \
        "no_sprint_id" \
        "$current_sprint_id"
    fi

    if [ ! -f "$HISTORY_FILE" ]; then
      block_stop \
        "Sprint review phase: sprint-history.json does not exist. A Sprint summary must be recorded before stopping." \
        "sprint_history_missing" \
        "$current_sprint_id"
    fi

    has_entry="$(jq --arg sid "$current_sprint_id" '[.sprints[]? | select(.id == $sid)] | length' "$HISTORY_FILE" 2>/dev/null || echo "0")"

    if [ "$has_entry" = "0" ]; then
      block_stop \
        "Sprint review phase: no entry found for Sprint '${current_sprint_id}' in sprint-history.json. Record the Sprint summary before stopping." \
        "sprint_history_missing" \
        "$current_sprint_id"
    fi

    allow_stop
    ;;

  retrospective)
    # improvements.json must have entry for current sprint
    if [ "$current_sprint_id" = "none" ] || [ "$current_sprint_id" = "null" ]; then
      block_stop \
        "Retrospective phase: no current Sprint ID in state.json." \
        "no_sprint_id" \
        "$current_sprint_id"
    fi

    if [ ! -f "$IMPROVEMENTS_FILE" ]; then
      block_stop \
        "Retrospective phase: improvements.json does not exist. Record improvement items before stopping." \
        "improvements_missing" \
        "$current_sprint_id"
    fi

    has_entry="$(jq --arg sid "$current_sprint_id" '[.entries[]? | select(.sprint_id == $sid)] | length' "$IMPROVEMENTS_FILE" 2>/dev/null || echo "0")"

    if [ "$has_entry" = "0" ]; then
      block_stop \
        "Retrospective phase: no improvement entries found for Sprint '${current_sprint_id}' in improvements.json. Record at least one improvement before stopping." \
        "improvements_missing" \
        "$current_sprint_id"
    fi

    allow_stop
    ;;

  integration_sprint)
    # test-results.json must exist with overall_status: "passed" or "passed_with_skips"
    if [ ! -f "$TEST_RESULTS_FILE" ]; then
      block_stop \
        "Integration Sprint: .scrum/test-results.json does not exist. Run the smoke-test skill before stopping." \
        "tests_missing" \
        ""
    fi

    overall_status="$(jq -r '.overall_status // "unknown"' "$TEST_RESULTS_FILE" 2>/dev/null || echo "unknown")"

    case "$overall_status" in
      passed|passed_with_skips)
        allow_stop
        ;;
      failed)
        # Show which categories failed
        failed_cats="$(jq -r '[.categories[]? | select(.status == "failed") | .name] | join(", ")' "$TEST_RESULTS_FILE" 2>/dev/null || echo "unknown")"
        block_stop \
          "Integration Sprint: automated tests failed. Failed categories: ${failed_cats}. Fix failures and re-run smoke-test before stopping." \
          "tests_failed" \
          "$failed_cats"
        ;;
      pending|running)
        block_stop \
          "Integration Sprint: automated tests are still ${overall_status}. Wait for smoke-test to complete before stopping." \
          "tests_${overall_status}" \
          ""
        ;;
      *)
        block_stop \
          "Integration Sprint: test-results.json has unexpected overall_status '${overall_status}'. Expected 'passed' or 'passed_with_skips'." \
          "tests_${overall_status}" \
          ""
        ;;
    esac
    ;;

  pbi_pipeline_active)
    # Active pipelines are derived from backlog.json (12-value SSOT): any
    # PBI whose status starts with `in_progress_` is mid-pipeline. The
    # filter excludes `in_progress_merge` (handoff awaiting SM action, not
    # a stuck pipeline) so it does not count toward the in-flight total.
    # `awaiting_cross_review` / `cross_review` / `done` are not
    # `in_progress_` prefixed and pass through. `escalated` requires a
    # recorded resolution.
    #
    # Block policy diverges by mode:
    #   * autonomy_loop_active (autonomous-PO mode + live watchdog):
    #     preserve historical behaviour — block on `in_flight_total > 0`
    #     so the watchdog's inner loop keeps the SM driving teammates, and
    #     `escalated` without resolution. autonomous_next_action() depends
    #     on the allow path meaning "all PBIs settled".
    #   * human mode (or autonomous mode with no live watchdog): do NOT
    #     block merely on `in_flight_total > 0`.
    #     Teammate liveness is handled by an external watchdog
    #     (scripts/stall-watchdog.sh). Only block on `escalated`
    #     without resolution — that is the one situation the SM must
    #     explicitly act on before stopping.
    #
    # Block message is compressed to a status-grouped count (e.g. "5
    # in-flight (2 design, 1 impl, ...)") rather than per-PBI listing,
    # because this hook fires on every SM turn-end and the verbose form
    # bloated context across many parallel pipelines. Escalated PBIs
    # without resolution are still listed by ID — they are rare and
    # require explicit operator action.
    if [ ! -f "$BACKLOG_FILE" ]; then
      allow_stop
    fi

    in_flight_summary="$(jq -r '
      [.items[]? | .status
        | select(startswith("in_progress_"))
        | select(. != "in_progress_merge")
        | sub("^in_progress_"; "")]
      | group_by(.)
      | map("\(length) \(.[0])")
      | join(", ")
    ' "$BACKLOG_FILE" 2>/dev/null || echo "")"

    in_flight_total="$(jq -r '
      [.items[]?
        | select(.status | startswith("in_progress_"))
        | select(.status != "in_progress_merge")]
      | length
    ' "$BACKLOG_FILE" 2>/dev/null || echo "0")"

    escalated_unresolved=""
    while IFS= read -r pbi_id; do
      [ -z "$pbi_id" ] && continue
      if [ ! -f ".scrum/pbi/$pbi_id/escalation-resolution.md" ]; then
        escalated_unresolved="${escalated_unresolved}${escalated_unresolved:+, }${pbi_id}"
      fi
    done < <(jq -r '.items[]? | select(.status == "escalated") | .id' "$BACKLOG_FILE" 2>/dev/null)

    if autonomy_loop_active; then
      # Autonomous path (live watchdog) — historical behaviour, do not change.
      if [ "$in_flight_total" -gt 0 ] || [ -n "$escalated_unresolved" ]; then
        msg="PBI pipeline active"
        if [ "$in_flight_total" -gt 0 ]; then
          msg="${msg}: ${in_flight_total} in-flight (${in_flight_summary}). Teammates work in worktrees — do NOT re-spawn. Verify via TaskGet (same session) or SendMessage probe before assuming failure. Re-spawn only after confirming termination AND missing artifact."
        fi
        if [ -n "$escalated_unresolved" ]; then
          msg="${msg}; escalated without resolution: ${escalated_unresolved}"
        fi
        # in_flight_total > 0 with no escalations is also a "still
        # running" signal under autonomy. We pass a block_kind
        # argument to block_stop for shape parity with the human
        # path; when `autonomy_loop_active` holds, block_stop's
        # `if autonomy_loop_active` branch bypasses the dedup ledger
        # — neither `stop-gate.json` nor any block_kind tag is read
        # or persisted here under the active autonomy loop.
        # escalated_unresolved is an exit-criteria miss that the SM must act on
        # — keep it BOUNDED so a Sprint that cannot resolve the escalation
        # (e.g. needs human/PO authority) trips the breaker and surfaces,
        # rather than pinning the session. A pure in-flight block (teammates
        # working, no escalation) is the healthy inner loop → UNBOUNDED.
        if [ -n "$escalated_unresolved" ]; then
          block_stop "$msg" "escalated_unresolved" "$escalated_unresolved"
        else
          block_stop "$msg" "pipeline_in_flight" "$in_flight_total" "unbounded"
        fi
      fi
    else
      # Human path (or autonomous mode with no live watchdog) — only
      # escalated_unresolved blocks. in-flight PBIs are allowed to coexist
      # with Stop; external watchdog monitors liveness.
      if [ -n "$escalated_unresolved" ]; then
        msg="PBI pipeline active; escalated without resolution: ${escalated_unresolved}"
        block_stop "$msg" "escalated_unresolved" "$escalated_unresolved"
      fi
    fi
    allow_stop
    ;;

  *)
    # Other phases: allow stop
    allow_stop
    ;;
esac
