#!/usr/bin/env bats
# tests/unit/scrum-state/test_set-sprint-developer.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/set-sprint-dev.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/set-sprint-dev.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/tests/fixtures/valid-sprint.json" .scrum/sprint.json
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "set-sprint-developer: existing dev-001-s1 active -> failed" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 status failed
  [ "$status" -eq 0 ]
  run jq -r '.developers[] | select(.id=="dev-001-s1").status' "$TEST_TMP/.scrum/sprint.json"
  [ "$output" = "failed" ]
}

@test "set-sprint-developer: registers new dev with default status active" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-002-s1 current_pbi pbi-007
  [ "$status" -eq 0 ]
  run jq -r '.developers[] | select(.id=="dev-002-s1").status' "$TEST_TMP/.scrum/sprint.json"
  [ "$output" = "active" ]
  run jq -r '.developers[] | select(.id=="dev-002-s1").current_pbi' "$TEST_TMP/.scrum/sprint.json"
  [ "$output" = "pbi-007" ]
}

@test "set-sprint-developer: rejects current_pbi_phase (field removed)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 current_pbi_phase impl_ut
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "set-sprint-developer: clears current_pbi via null" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 current_pbi pbi-005
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 current_pbi null
  [ "$status" -eq 0 ]
  run jq -r '.developers[] | select(.id=="dev-001-s1").current_pbi' "$TEST_TMP/.scrum/sprint.json"
  [ "$output" = "null" ]
}

@test "set-sprint-developer: rejects unknown field" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 wibble x
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "set-sprint-developer: rejects bad dev id format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" devOne status active
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad dev id"* ]]
}

@test "set-sprint-developer: rejects bad status value" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 status wibble
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad status"* ]]
}

@test "set-sprint-developer: rejects bad current_pbi format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 current_pbi WIBBLE
  [ "$status" -eq 64 ]
}

@test "set-sprint-developer: requires exactly three args" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-sprint-developer.sh" dev-001-s1 status
  [ "$status" -eq 64 ]
}
