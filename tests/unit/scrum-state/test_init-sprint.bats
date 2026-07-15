#!/usr/bin/env bats
# tests/unit/scrum-state/test_init-sprint.bats — initialise sprint.json and
# set state.current_sprint_id in one call, with rollback on the second write.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/init-sprint.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/init-sprint.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  SCRIPT="$PROJECT_ROOT/scripts/scrum/init-sprint.sh"
  SPRINT="$TEST_TMP/.scrum/sprint.json"
  STATE="$TEST_TMP/.scrum/state.json"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# A valid state.json with the given phase. phase=new is the normal precondition;
# an invalid phase is used to force the second (state.json) write to fail.
write_state() {
  local phase="${1:-new}"
  jq -n --arg phase "$phase" '{
    phase: $phase, current_sprint_id: null, product_goal: null,
    created_at: "2026-06-01T00:00:00Z", updated_at: "2026-06-01T00:00:00Z"
  }' > "$STATE"
}

@test "init-sprint: creates sprint.json and sets state.current_sprint_id" {
  write_state new
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" sprint-001 --goal "Ship it"
  [ "$status" -eq 0 ]
  [ -f "$SPRINT" ]
  run jq -r '.id, .goal, .status' "$SPRINT"
  [ "${lines[0]}" = "sprint-001" ]
  [ "${lines[1]}" = "Ship it" ]
  [ "${lines[2]}" = "planning" ]
  run jq -r '.current_sprint_id' "$STATE"
  [ "$output" = "sprint-001" ]
}

@test "init-sprint: refuses when sprint.json already exists" {
  write_state new
  echo '{"id":"sprint-000"}' > "$SPRINT"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"already exists"* ]]
}

@test "init-sprint: fails E_FILE_MISSING when state.json absent (no orphan created)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" sprint-001
  [ "$status" -eq 67 ]
  # sprint.json is never created — the existence check precedes atomic_create.
  [ ! -f "$SPRINT" ]
}

@test "init-sprint: rolls back sprint.json when state write fails (no orphan)" {
  # An invalid phase makes the state.json result violate state.schema, so the
  # SECOND write fails after sprint.json is already created. FIX 2 must remove
  # the just-created sprint.json rather than strand a half-init.
  write_state bogus_phase
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" sprint-001 --goal "Ship it"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolled back"* ]]
  # The orphan sprint.json must not survive.
  [ ! -f "$SPRINT" ]
}
