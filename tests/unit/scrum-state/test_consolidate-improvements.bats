#!/usr/bin/env bats
# tests/unit/scrum-state/test_consolidate-improvements.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/consolidate-imp.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/consolidate-imp.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/improvements.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/consolidate-improvements.sh"
  APPEND="$PROJECT_ROOT/scripts/scrum/append-improvement.sh"
  # Seed three active entries via the sanctioned append wrapper.
  env SCRUM_VALIDATOR_OVERRIDE=python "$APPEND" --sprint sprint-001 --description "first"
  env SCRUM_VALIDATOR_OVERRIDE=python "$APPEND" --sprint sprint-002 --description "second"
  env SCRUM_VALIDATOR_OVERRIDE=python "$APPEND" --sprint sprint-003 --description "third"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "consolidate: archives named entries and bumps last_consolidation_sprint" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --archive imp-0001 --archive imp-0002
  [ "$status" -eq 0 ]
  [[ "$output" == *"archived 2"* ]]
  run jq -r '.entries[0].status' .scrum/improvements.json
  [ "$output" = "archived" ]
  run jq -r '.entries[0].archived_at' .scrum/improvements.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  run jq -r '.entries[2].status' .scrum/improvements.json
  [ "$output" = "active" ]
  run jq -r '.entries[2].archived_at' .scrum/improvements.json
  [ "$output" = "null" ]
  run jq -r '.last_consolidation_sprint' .scrum/improvements.json
  [ "$output" = "sprint-003" ]
}

@test "consolidate: zero --archive still bumps the marker (nothing-stale pass)" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --sprint sprint-003
  [ "$status" -eq 0 ]
  [[ "$output" == *"archived 0"* ]]
  run jq -r '.last_consolidation_sprint' .scrum/improvements.json
  [ "$output" = "sprint-003" ]
  run jq -r '[.entries[] | select(.status == "active")] | length' .scrum/improvements.json
  [ "$output" = "3" ]
}

@test "consolidate: already-archived id is skipped with WARN (idempotent retry)" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --sprint sprint-003 --archive imp-0001
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-004 --archive imp-0001 --archive imp-0002
  [ "$status" -eq 0 ]
  [[ "$output" == *"imp-0001 already archived"* ]]
  [[ "$output" == *"archived 1"* ]]
  run jq -r '.entries[1].status' .scrum/improvements.json
  [ "$output" = "archived" ]
  run jq -r '.last_consolidation_sprint' .scrum/improvements.json
  [ "$output" = "sprint-004" ]
}

@test "consolidate: unknown improvement id is a hard error" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --archive imp-9999
  [ "$status" -eq 64 ]
  [[ "$output" == *"no such improvement entry: imp-9999"* ]]
  run jq -r '.last_consolidation_sprint' .scrum/improvements.json
  [ "$output" = "null" ]
}

@test "consolidate: rejects bad --archive pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --archive imp-1
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --archive"* ]]
}

@test "consolidate: rejects missing --sprint" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --archive imp-0001
  [ "$status" -eq 64 ]
  [[ "$output" == *"--sprint required"* ]]
}

@test "consolidate: rejects bad --sprint pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint bogus --archive imp-0001
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --sprint"* ]]
}

@test "consolidate: fails E_FILE_MISSING when improvements.json absent" {
  rm .scrum/improvements.json
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --sprint sprint-003
  [ "$status" -eq 67 ]
}

@test "consolidate: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "consolidate: accepts 5-digit --archive ids past imp-9999" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --archive imp-10000
  [ "$status" -eq 64 ]
  [[ "$output" == *"no such improvement entry: imp-10000"* ]]
}
