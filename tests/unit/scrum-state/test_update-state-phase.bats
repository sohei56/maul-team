#!/usr/bin/env bats
# tests/unit/scrum-state/test_update-state-phase.bats

load lib/helpers.bash

setup() {
  scrum_state_setup state.schema.json valid-state.json state.json upd-state-phase
}

teardown() {
  scrum_state_teardown
}

@test "update-state-phase: → review" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-state-phase.sh" review
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/state.json"
  [ "$output" = "review" ]
}

@test "update-state-phase: accepts pbi_pipeline_active" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-state-phase.sh" pbi_pipeline_active
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/state.json"
  [ "$output" = "pbi_pipeline_active" ]
}

@test "update-state-phase: accepts uat_release" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-state-phase.sh" uat_release
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/state.json"
  [ "$output" = "uat_release" ]
}

@test "update-state-phase: rejects bogus phase" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-state-phase.sh" giga_review
  [ "$status" -eq 64 ]
}

@test "update-state-phase: requires exactly one arg" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-state-phase.sh"
  [ "$status" -eq 64 ]
}
