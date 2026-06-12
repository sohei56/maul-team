#!/usr/bin/env bats
# tests/unit/hooks/test_stop_dispatch.bats
#
# Verifies the unified Stop dispatcher at hooks/stop-dispatch.sh.
#
# Contract under test:
#   * dashboard-event.sh receives the Stop payload (best-effort) BEFORE
#     completion-gate.sh is consulted, so the Stop is recorded even when
#     the gate decides to block (exit 2).
#   * completion-gate.sh's exit code is propagated verbatim.
#   * Empty stdin must not crash the dispatcher.
#   * The dispatcher must NOT modify the payload between the two children.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  DISPATCHER="$PROJECT_ROOT/hooks/stop-dispatch.sh"
  FIXTURES="$PROJECT_ROOT/tests/fixtures"
  TEST_TMP="$(mktemp -d /tmp/claude/stop-dispatch.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/stop-dispatch.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Build a minimal Stop hook payload with a known session_id so we can
# observe it landed in the dashboard's event log.
stop_payload() {
  local sid="${1:-sess-x}"
  printf '{"hook_event_name":"Stop","session_id":"%s","reason":"completed"}' "$sid"
}

# -----------------------------------------------------------------
# (a) Gate allow → dispatcher exit 0 AND dashboard event recorded.
# -----------------------------------------------------------------

@test "stop-dispatch: ungated phase → exit 0 and dashboard.json appended" {
  # No state.json → gate allows (exit 0).
  run bash -c "printf '%s' '$(stop_payload sess-a)' | bash $DISPATCHER"
  [ "$status" -eq 0 ]

  # dashboard-event.sh writes a status_transition entry for Stop events.
  [ -f .scrum/dashboard.json ]
  run jq -e '.events[-1].type == "status_transition"' .scrum/dashboard.json
  [ "$status" -eq 0 ]
  run jq -e '.events[-1].detail | test("Session stopped")' .scrum/dashboard.json
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (b) Gate block → dispatcher exit 2 AND dashboard event still recorded.
# -----------------------------------------------------------------

@test "stop-dispatch: gate-blocked Stop still appends dashboard event" {
  # Force a block: review phase with an incomplete PBI.
  jq '.phase = "review"' "$FIXTURES/valid-state.json" > .scrum/state.json
  cp "$FIXTURES/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES/valid-backlog.json" > .scrum/backlog.json

  run bash -c "printf '%s' '$(stop_payload sess-b)' | bash $DISPATCHER"
  [ "$status" -eq 2 ]

  # Dashboard event must have been written BEFORE the gate raised exit 2.
  [ -f .scrum/dashboard.json ]
  run jq -e '.events[-1].type == "status_transition"' .scrum/dashboard.json
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (c) Empty stdin → must not crash.
# -----------------------------------------------------------------

@test "stop-dispatch: empty stdin does not crash" {
  # Pipe empty input — dispatcher should still consult the gate.
  run bash -c ": | bash $DISPATCHER"
  # No state.json → gate allows.
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (d) Payload propagation: agent_id from Stop payload must land in the
#     dashboard event entry (proves the dispatcher forwarded stdin).
# -----------------------------------------------------------------

@test "stop-dispatch: payload session_id is forwarded to dashboard-event.sh" {
  run bash -c "printf '%s' '$(stop_payload sess-c-1234)' | bash $DISPATCHER"
  [ "$status" -eq 0 ]
  # dashboard-event.sh derives agent_id from session_id and shortens it
  # to 8 chars when it matches UUID-style; "sess-c-1234" is not UUID-like
  # so it lands verbatim.
  run jq -r '.events[-1].agent_id' .scrum/dashboard.json
  [ "$output" = "sess-c-1234" ]
}
