#!/usr/bin/env bats
# tests/unit/hooks/test_completion_gate_autonomous.bats
#
# Verifies the autonomous-PO interception layer added to
# hooks/completion-gate.sh. The fixture strategy mirrors
# tests/unit/hooks/test_autonomy_lib.bats: each test materialises a fresh
# .scrum/ directory in a tmp cwd, writes the relevant fixtures, then runs
# the hook with an optional stdin payload encoding session_id.
#
# Contract under test (see commit message for full spec):
#   * human mode  → no behaviour change for any phase
#   * agent mode + lead session_id:
#       - phase = complete | retrospective(records ok) | integration_sprint(passed)
#         → allow stop (exit 0)
#       - phase = backlog_created AND sprint-history non-empty (Sprint
#         rollover from the Retrospective handshake) → allow stop (exit 0)
#       - phase = backlog_created with empty/absent sprint-history (initial
#         backlog) → block (exit 2) with sprint-planning instruction
#       - any other phase that the existing logic allowed
#         → block (exit 2) with a phase-specific "do not stop" reason
#       - exceeding stop_block_budget_per_phase
#         → record_circuit_breaker + allow stop (exit 0)
#       - existing block paths (e.g. pbi_pipeline_active with in-flight)
#         remain blocked
#   * agent mode + non-lead session_id → no autonomous interception

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  HOOK="$PROJECT_ROOT/hooks/completion-gate.sh"
  FIXTURES="$PROJECT_ROOT/tests/fixtures"
  TEST_TMP="$(mktemp -d /tmp/claude/completion-gate-autonomous.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/completion-gate-autonomous.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# -------- helpers ---------------------------------------------------------

write_config_agent() {
  # Optional second arg overrides the stop_block_budget_per_phase.
  local budget="${1:-8}"
  cat > .scrum/config.json <<EOF
{"po_mode": "agent", "autonomous": {"stop_block_budget_per_phase": $budget}}
EOF
}

write_config_human() {
  cat > .scrum/config.json <<'EOF'
{"po_mode": "human"}
EOF
}

write_autonomy() {
  local lead="${1:-sess-lead}"
  local phase="${2:-idle}"
  local count="${3:-0}"
  # 4th arg: watchdog_pid. Default to this (live) test process so the gate
  # treats the watchdog as alive and autonomous interception stays in force.
  # Pass a dead pid (see dead_pid) to exercise the no-live-watchdog fallback.
  local pid="${4:-$$}"
  cat > .scrum/autonomy.json <<EOF
{
  "run_id": "run-test",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": "$lead",
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "$phase", "count": $count},
  "circuit_breaker_tripped": null,
  "last_failure": null,
  "watchdog_pid": $pid
}
EOF
}

# dead_pid — echo a PID that is guaranteed not to be running (spawn a trivial
# process, wait for it to exit, return its now-dead pid). Used to simulate an
# autonomous run whose watchdog has died / is absent.
dead_pid() {
  local p
  sh -c 'exit 0' &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

write_state_phase() {
  local phase="$1"
  local sprint_id="${2:-sprint-001}"
  jq -n --arg p "$phase" --arg s "$sprint_id" \
    '{phase: $p, current_sprint_id: $s, product_goal: "g", created_at: "2026-06-12T00:00:00Z", updated_at: "2026-06-12T00:00:00Z"}' \
    > .scrum/state.json
}

stdin_session() {
  # Echo a Claude Code Stop-hook payload with a session_id.
  local sid="$1"
  printf '{"session_id":"%s","hook_event_name":"Stop"}' "$sid"
}

# ------------------------------------------------------------------
# (a) Human mode regression: representative phases must keep behaviour.
# ------------------------------------------------------------------

@test "human mode: backlog_created allows stop (no interception)" {
  write_config_human
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "human mode: review with all done allows stop" {
  write_config_human
  write_state_phase review
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "done"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "human mode: pbi_pipeline_active with in-flight allows stop (block-noise reduction)" {
  # Behaviour change (block-noise reduction): under human mode, in-flight
  # PBIs alone no longer block Stop. Teammate liveness is handled by an
  # external watchdog (scripts/stall-watchdog.sh). Only escalated PBIs
  # without a recorded resolution still block — covered in a separate
  # test below.
  write_config_human
  write_state_phase pbi_pipeline_active
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# (b) Agent mode + lead session: backlog_created blocks with instruction.
# ------------------------------------------------------------------

@test "agent mode lead session: backlog_created blocks with sprint-planning instruction" {
  write_config_agent
  write_autonomy sess-lead backlog_created 0
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"do NOT stop"* ]]
  [[ "$output" == *"sprint-planning"* ]]
  # Counter advanced.
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "1" ]
  run jq -r '.stop_blocks.phase' .scrum/autonomy.json
  [ "$output" = "backlog_created" ]
}

@test "agent mode lead session: backlog_created ROLLOVER (sprint-history non-empty) allows stop (recycle checkpoint)" {
  # After a Retrospective advances phase to backlog_created for the next
  # Sprint, the stop is a clean recycle point — the watchdog spawns a fresh
  # session for the next Sprint's planning.
  write_config_agent
  write_autonomy sess-lead backlog_created 0
  write_state_phase backlog_created sprint-001
  jq -n '{sprints: [{id: "sprint-001", goal: "g"}]}' > .scrum/sprint-history.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
  # Recycle checkpoint must NOT bump the stop-block counter.
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "0" ]
}

@test "agent mode lead session: sprint_review (after entry recorded) blocks with retrospective instruction" {
  write_config_agent
  write_autonomy sess-lead sprint_review 0
  write_state_phase sprint_review sprint-001
  # sprint-history entry exists -> existing exit criteria passes
  jq -n '{sprints: [{id: "sprint-001", goal: "g"}]}' > .scrum/sprint-history.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"retrospective"* ]]
}

# ------------------------------------------------------------------
# (c) Agent mode lead session + retrospective with improvements recorded
#     → checkpoint, allow stop so watchdog recycles session.
# ------------------------------------------------------------------

@test "agent mode lead session: retrospective with improvements recorded allows stop (checkpoint)" {
  write_config_agent
  write_autonomy sess-lead retrospective 0
  write_state_phase retrospective sprint-001
  jq -n '{entries: [{id: "imp-1", sprint_id: "sprint-001", description: "x", status: "active", created_at: "2026-06-12T00:00:00Z", archived_at: null}]}' > .scrum/improvements.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# (d) Agent mode lead session + integration_sprint passed → allow.
# ------------------------------------------------------------------

@test "agent mode lead session: integration_sprint passed allows stop (checkpoint)" {
  write_config_agent
  write_autonomy sess-lead integration_sprint 0
  write_state_phase integration_sprint
  jq -n '{overall_status: "passed", categories: []}' > .scrum/test-results.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# (e) Agent mode lead session + complete → allow.
# ------------------------------------------------------------------

@test "agent mode lead session: complete phase allows stop" {
  write_config_agent
  write_autonomy sess-lead complete 0
  write_state_phase complete
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# (f) Teammate session_id → no autonomous interception (allow).
# ------------------------------------------------------------------

@test "agent mode non-lead session: backlog_created is NOT intercepted (allow)" {
  write_config_agent
  write_autonomy sess-lead backlog_created 0
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-teammate)' | $HOOK"
  [ "$status" -eq 0 ]
  # Counter must NOT have been touched (lead-only interception).
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "0" ]
}

# ------------------------------------------------------------------
# (g) stop_block_budget exhausted → trip circuit breaker + allow.
# ------------------------------------------------------------------

@test "agent mode lead session: exceeding stop_block_budget trips circuit breaker and allows stop" {
  write_config_agent 2
  # count=2 with same phase: next bump → 3, which is > budget 2.
  write_autonomy sess-lead backlog_created 2
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
  run jq -r '.circuit_breaker_tripped.phase' .scrum/autonomy.json
  [ "$output" = "backlog_created" ]
  run jq -r '.circuit_breaker_tripped.at' .scrum/autonomy.json
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ------------------------------------------------------------------
# (h) Existing block (pbi_pipeline_active with in-flight) stays blocked
#     even under agent mode — interception only fires from the allow path.
# ------------------------------------------------------------------

@test "agent mode lead session: pbi_pipeline_active with in-flight PBI stays blocked (existing gate)" {
  write_config_agent
  write_autonomy sess-lead pbi_pipeline_active 0
  cp "$FIXTURES/valid-state.json" .scrum/state.json
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 2 ]
  # The block message must come from the existing pipeline-active gate
  # (in-flight wording), not the autonomous interception.
  [[ "$output" == *"in-flight"* ]]
  # Counter must NOT have been bumped — autonomous interception runs only
  # when the existing path would have allowed.
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "0" ]
}

# ------------------------------------------------------------------
# Additional: pbi_pipeline_active with all PBIs settled
# → existing gate allows → autonomous interception blocks with instruction.
# ------------------------------------------------------------------

@test "agent mode lead session: pbi_pipeline_active with all PBIs done blocks with advance-to-review instruction" {
  write_config_agent
  write_autonomy sess-lead pbi_pipeline_active 0
  cp "$FIXTURES/valid-state.json" .scrum/state.json
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "done"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"review"* ]]
}

# ------------------------------------------------------------------
# Human-mode block-reduction surface (gated by hooks/lib/stop-gate-state.sh)
# ------------------------------------------------------------------
# The following tests verify that human mode:
#   * No longer blocks merely on in-flight PBIs during pbi_pipeline_active
#     (external watchdog handles teammate liveness now).
#   * Still blocks for escalated PBIs without resolution, but the second
#     identical block in a row is suppressed (logged-only allow).
#   * Block messages emit Reason text on the FIRST block of a tuple, and
#     no Reason on REPEATs — confirming the dedup ledger is consulted.

@test "human mode + pbi_pipeline_active: in-flight PBIs alone allow stop (no Reason in stderr)" {
  write_config_human
  write_state_phase pbi_pipeline_active sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_impl"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 0 ]
  # No "Reason:" text from block_stop should appear.
  [[ "$output" != *"Reason:"* ]]
  # And the dedup ledger should NOT be created (no block fired).
  [ ! -f .scrum/stop-gate.json ]
}

@test "human mode + escalated unresolved: first block exits 2, second identical block exits 0" {
  write_config_human
  write_state_phase pbi_pipeline_active sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "escalated" | .items[0].id = "pbi-009"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  # No escalation-resolution.md yet → block.
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"escalated without resolution"* ]]
  [[ "$output" == *"pbi-009"* ]]
  # Ledger should now exist with count=1.
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "1" ]
  # Second identical block — suppressed.
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 0 ]
  # Ledger bumped to 2.
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "2" ]
}

@test "human mode + sprint_review missing entry: first block exit 2, repeat exit 0, sprint_id change re-blocks" {
  write_config_human
  write_state_phase sprint_review sprint-001
  # No sprint-history.json file at all → block on sprint_history_missing.
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sprint-history.json does not exist"* ]]
  # Same situation → suppressed.
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 0 ]
  # Sprint ID changes → signature changes → block fires again.
  write_state_phase sprint_review sprint-002
  run bash -c "printf '%s' '$(stdin_session sess-x)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
}

@test "autonomy enabled: pbi_pipeline_active with in-flight blocks but does NOT touch stop-gate.json" {
  write_config_agent
  write_autonomy sess-lead pbi_pipeline_active 0
  cp "$FIXTURES/valid-state.json" .scrum/state.json
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  [ ! -f .scrum/stop-gate.json ]
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
  # Dedup ledger must NOT exist — autonomy path bypasses it so the
  # watchdog contract keeps firing on every Stop.
  [ ! -f .scrum/stop-gate.json ]
}

# ------------------------------------------------------------------
# (i) No live watchdog (BUG-3): autonomous config but watchdog_pid is
#     dead/absent → the gate must NOT block-every-Stop (which would storm a
#     session nothing will re-launch). It degrades to human-mode behaviour.
# ------------------------------------------------------------------

@test "agent mode, DEAD watchdog_pid: backlog_created allows stop (no storm)" {
  # Same situation that blocks under a LIVE watchdog (initial backlog), but
  # with a dead pid the autonomous interception must not fire.
  write_config_agent
  write_autonomy sess-lead backlog_created 0 "$(dead_pid)"
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
  # Counter must NOT have advanced — interception did not run.
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "0" ]
}

@test "agent mode, ABSENT watchdog_pid: backlog_created allows stop (legacy autonomy.json)" {
  # An autonomy.json written before watchdog_pid existed (field absent) must
  # be treated as "no live watchdog" → human-mode fallback.
  write_config_agent
  write_autonomy sess-lead backlog_created 0
  jq 'del(.watchdog_pid)' .scrum/autonomy.json > .scrum/autonomy.json.tmp \
    && mv .scrum/autonomy.json.tmp .scrum/autonomy.json
  write_state_phase backlog_created
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "agent mode, DEAD watchdog_pid: pbi_pipeline_active in-flight uses human ledger (allows, no storm)" {
  # Under a live watchdog this blocks on in-flight; with a dead watchdog it
  # must follow the human path (in-flight alone does NOT block).
  write_config_agent
  write_autonomy sess-lead pbi_pipeline_active 0 "$(dead_pid)"
  write_state_phase pbi_pipeline_active sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_impl"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# (j) block_stop terminal gap (P0-a): exit-criteria-miss phases reached via
#     block_stop (e.g. `review` with a stuck PBI) historically did `exit 2`
#     directly under autonomy and NEVER reached the circuit breaker, pinning
#     the session in an unbounded hard block. They must now route through the
#     per-phase breaker: block within budget, trip + allow once exceeded.
# ------------------------------------------------------------------

@test "agent mode lead session: review with a non-done PBI BLOCKS within budget and surfaces stop-block count" {
  write_config_agent 8
  write_autonomy sess-lead review 0
  write_state_phase review sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  # status=escalated (not done) → review exit-criteria miss → block_stop.
  jq '.items[0].status = "escalated"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not done"* ]]
  # Bounded block now consumes the per-phase budget (regression: it used to
  # exit 2 without touching the counter).
  [[ "$output" == *"stop-block 1/8"* ]]
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "1" ]
}

@test "agent mode lead session: review with a stuck PBI TRIPS the breaker once budget exceeded (the missing terminal)" {
  write_config_agent 2
  # count=2, same phase: next bump → 3 > budget 2 → trip.
  write_autonomy sess-lead review 2
  write_state_phase review sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "escalated"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  # Breaker trips → allow exit so the watchdog flags the run (was: infinite
  # in-session hard block with no path to the breaker).
  [ "$status" -eq 0 ]
  run jq -r '.circuit_breaker_tripped.phase' .scrum/autonomy.json
  [ "$output" = "review" ]
}

@test "agent mode lead session: escalated_unresolved is BOUNDED and trips the breaker" {
  # The real incident scenario — an escalated PBI with no recorded resolution
  # that the team cannot auto-resolve must surface, not pin the session.
  write_config_agent 2
  write_autonomy sess-lead pbi_pipeline_active 2
  write_state_phase pbi_pipeline_active sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "escalated" | .items[0].id = "pbi-009"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  # No .scrum/pbi/pbi-009/escalation-resolution.md → unresolved.
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  [ "$status" -eq 0 ]
  run jq -r '.circuit_breaker_tripped.phase' .scrum/autonomy.json
  [ "$output" = "pbi_pipeline_active" ]
}

@test "agent mode lead session: pure in-flight block is UNBOUNDED (never trips the breaker)" {
  # A healthy Sprint legitimately blocks more than the budget within one
  # iteration (the watchdog resets the counter per iteration). The in-flight
  # inner loop must NOT consume the breaker budget or it would kill long
  # Sprints. count is already past budget here.
  write_config_agent 2
  write_autonomy sess-lead pbi_pipeline_active 5
  write_state_phase pbi_pipeline_active sprint-001
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_impl"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json
  run bash -c "printf '%s' '$(stdin_session sess-lead)' | $HOOK 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"in-flight"* ]]
  # Unbounded path must NOT bump the counter or trip the breaker.
  run jq -r '.stop_blocks.count' .scrum/autonomy.json
  [ "$output" = "5" ]
  run jq -r '.circuit_breaker_tripped' .scrum/autonomy.json
  [ "$output" = "null" ]
}
