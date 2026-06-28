#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-sprint-history.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-sh.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-sh.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint-history.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/append-sprint-history.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-sprint-history: initial append creates file and records the Sprint" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --id sprint-001 --goal "Ship the MVP"
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-001" ]
  [ -f "$TEST_TMP/.scrum/sprint-history.json" ]
  run jq -r '.sprints | length' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "1" ]
  run jq -r '.sprints[0].id' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "sprint-001" ]
  run jq -r '.sprints[0].goal' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "Ship the MVP" ]
  # completed_at defaults to now (present, non-empty).
  run jq -r '.sprints[0].completed_at | length > 0' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "true" ]
}

@test "append-sprint-history: records all optional fields when supplied" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --id sprint-002 --goal "Add reporting" \
    --type development --pbis-completed 4 --pbis-total 5 \
    --started-at 2026-06-01T00:00:00Z --completed-at 2026-06-14T00:00:00Z
  [ "$status" -eq 0 ]
  run jq -r '.sprints[0].type' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "development" ]
  run jq -r '.sprints[0].pbis_completed' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "4" ]
  run jq -r '.sprints[0].pbis_total' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "5" ]
  run jq -r '.sprints[0].started_at' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "2026-06-01T00:00:00Z" ]
  run jq -r '.sprints[0].completed_at' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "2026-06-14T00:00:00Z" ]
}

@test "append-sprint-history: second distinct Sprint appends (length 2, order preserved)" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-001 --goal "first"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-002 --goal "second"
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-002" ]
  run jq -r '.sprints | length' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "2" ]
  run jq -r '.sprints[-1].id' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "sprint-002" ]
}

@test "append-sprint-history: idempotent on duplicate id (no-op, no duplicate, exit 0)" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-001 --goal "original"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-001 --goal "retry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-001"* ]]
  # Still exactly one entry, and the original goal is untouched (append-only).
  run jq -r '.sprints | length' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "1" ]
  run jq -r '.sprints[0].goal' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$output" = "original" ]
}

@test "append-sprint-history: optional fields are absent when not passed" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-001 --goal "minimal"
  run jq -e '.sprints[0] | has("type") | not' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$status" -eq 0 ]
  run jq -e '.sprints[0] | has("pbis_completed") | not' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$status" -eq 0 ]
  run jq -e '.sprints[0] | has("started_at") | not' "$TEST_TMP/.scrum/sprint-history.json"
  [ "$status" -eq 0 ]
}

@test "append-sprint-history: rejects missing --id" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --goal "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--id required"* ]]
}

@test "append-sprint-history: rejects missing --goal" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"--goal required"* ]]
}

@test "append-sprint-history: rejects bad --id pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --id bogus --goal "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --id"* ]]
}

@test "append-sprint-history: rejects bad --type" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --id sprint-001 --goal "x" --type bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --type"* ]]
}

@test "append-sprint-history: rejects non-integer --pbis-completed" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --id sprint-001 --goal "x" --pbis-completed five
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --pbis-completed"* ]]
}

@test "append-sprint-history: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --id sprint-001 --goal "x" --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}
