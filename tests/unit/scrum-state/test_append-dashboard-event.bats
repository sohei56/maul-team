#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-dashboard-event.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-dash.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-dash.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/dashboard.schema.json" docs/contracts/scrum-state/
  printf '{"max_events":100,"events":[]}\n' > .scrum/dashboard.json
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-dashboard-event: file_changed event with file path" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" \
    --type file_changed --agent dev-001-s1 --file "src/x.py" --change-type modify
  [ "$status" -eq 0 ]
  run jq -r '.events[0].type' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "file_changed" ]
  run jq -r '.events[0].agent_id' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "dev-001-s1" ]
  run jq -r '.events[0].file_path' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "src/x.py" ]
}

@test "append-dashboard-event: status_transition event with from/to" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" \
    --type status_transition --status-from refined --status-to in_progress_design
  [ "$status" -eq 0 ]
  run jq -r '"\(.events[0].status_from)→\(.events[0].status_to)"' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "refined→in_progress_design" ]
}

@test "append-dashboard-event: minimal event has nulls for unset optional fields" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" --type test_run
  [ "$status" -eq 0 ]
  run jq -r '.events[0].agent_id' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "null" ]
  run jq -r '.events[0].file_path' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "null" ]
}

@test "append-dashboard-event: 20 concurrent appends land cleanly" {
  for i in $(seq 1 20); do
    env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" \
      --type test_run --detail "n$i" &
  done
  wait
  run jq -r '.events | length' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "20" ]
}

@test "append-dashboard-event: rejects missing --type" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" --agent x
  [ "$status" -eq 64 ]
  [[ "$output" == *"--type required"* ]]
}

@test "append-dashboard-event: rejects bogus type" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" --type giga_event
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --type"* ]]
}

@test "append-dashboard-event: rejects bad --pbi format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" --type test_run --pbi WIBBLE
  [ "$status" -eq 64 ]
}

@test "append-dashboard-event: preserves unknown top-level fields" {
  printf '{"max_events":100,"events":[],"_extra":[{"k":"v"}]}\n' > "$TEST_TMP/.scrum/dashboard.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-dashboard-event.sh" --type test_run
  [ "$status" -eq 0 ]
  run jq -r '._extra | length' "$TEST_TMP/.scrum/dashboard.json"
  [ "$output" = "1" ]
}
