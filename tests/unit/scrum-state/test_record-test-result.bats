#!/usr/bin/env bats
# tests/unit/scrum-state/test_record-test-result.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/record-tr.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/record-tr.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/test-results.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/record-test-result.sh"
  RESULTS="$TEST_TMP/.scrum/test-results.json"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

record() {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" "$@"
}

@test "record-test-result: first record creates the file and sets overall_status" {
  record --name unit --status passed --total 15 --passed 15 --failed 0 --skipped 0 --runner-command "npm test"
  [ "$status" -eq 0 ]
  [ "$output" = "passed" ]
  [ -f "$RESULTS" ]
  run jq -r '.categories | length' "$RESULTS"
  [ "$output" = "1" ]
  run jq -r '.categories[0].name' "$RESULTS"
  [ "$output" = "unit" ]
  run jq -r '.categories[0].runner_command' "$RESULTS"
  [ "$output" = "npm test" ]
  # started_at and updated_at are present.
  run jq -r '(.started_at | length > 0) and (.updated_at | length > 0)' "$RESULTS"
  [ "$output" = "true" ]
}

@test "record-test-result: executed_at defaults to now when not supplied" {
  record --name unit --status passed
  [ "$status" -eq 0 ]
  run jq -r '.categories[0].executed_at | length > 0' "$RESULTS"
  [ "$output" = "true" ]
}

@test "record-test-result: distinct categories append (length 2)" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --name unit --status passed
  record --name smoke --status passed
  [ "$status" -eq 0 ]
  run jq -r '.categories | length' "$RESULTS"
  [ "$output" = "2" ]
  run jq -r '[.categories[].name] | join(",")' "$RESULTS"
  [ "$output" = "unit,smoke" ]
}

@test "record-test-result: re-recording same name replaces (upsert, no duplicate)" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --name e2e --status failed --total 3 --passed 1 --failed 2
  # overall_status is now failed
  run jq -r '.overall_status' "$RESULTS"
  [ "$output" = "failed" ]
  # Re-run the same suite green -> replaces the failing entry.
  record --name e2e --status passed --total 3 --passed 3 --failed 0
  [ "$status" -eq 0 ]
  [ "$output" = "passed" ]
  run jq -r '.categories | length' "$RESULTS"
  [ "$output" = "1" ]
  run jq -r '.categories[0].status' "$RESULTS"
  [ "$output" = "passed" ]
}

@test "record-test-result: overall_status any-failed wins" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --name unit --status passed
  record --name e2e --status failed --total 2 --passed 0 --failed 2
  [ "$output" = "failed" ]
}

@test "record-test-result: overall_status passed_with_skips when a category is skipped" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --name unit --status passed
  record --name browser --status skipped --runner-command "none detected"
  [ "$output" = "passed_with_skips" ]
}

@test "record-test-result: errors are recorded as {test_name, message}" {
  record --name e2e --status failed --total 2 --passed 1 --failed 1 \
    --error "test_login::assertion failed" --error "message only"
  [ "$status" -eq 0 ]
  run jq -r '.categories[0].errors | length' "$RESULTS"
  [ "$output" = "2" ]
  run jq -r '.categories[0].errors[0].test_name' "$RESULTS"
  [ "$output" = "test_login" ]
  run jq -r '.categories[0].errors[0].message' "$RESULTS"
  [ "$output" = "assertion failed" ]
  run jq -e '.categories[0].errors[1] | (has("test_name") | not) and .message == "message only"' "$RESULTS"
  [ "$status" -eq 0 ]
}

@test "record-test-result: optional numeric fields are absent when not passed" {
  record --name unit --status passed
  run jq -e '.categories[0] | (has("total") | not) and (has("errors") | not) and (has("runner_command") | not)' "$RESULTS"
  [ "$status" -eq 0 ]
}

@test "record-test-result: rejects missing --name" {
  record --status passed
  [ "$status" -eq 64 ]
  [[ "$output" == *"--name required"* ]]
}

@test "record-test-result: rejects missing --status" {
  record --name unit
  [ "$status" -eq 64 ]
  [[ "$output" == *"--status required"* ]]
}

@test "record-test-result: rejects bad --status" {
  record --name unit --status bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --status"* ]]
}

@test "record-test-result: rejects non-integer --total" {
  record --name unit --status passed --total five
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --total"* ]]
}

@test "record-test-result: rejects more than 10 --error entries" {
  record --name e2e --status failed \
    --error e1 --error e2 --error e3 --error e4 --error e5 \
    --error e6 --error e7 --error e8 --error e9 --error e10 --error e11
  [ "$status" -eq 64 ]
  [[ "$output" == *"too many --error"* ]]
}

@test "record-test-result: rejects unknown flag" {
  record --name unit --status passed --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}
