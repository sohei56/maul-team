#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-improvement.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-imp.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-imp.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/improvements.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/append-improvement.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-improvement: initial append creates file and assigns imp-0001" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-001 --description "Refine PBI estimation"
  [ "$status" -eq 0 ]
  [ "$output" = "imp-0001" ]
  [ -f "$TEST_TMP/.scrum/improvements.json" ]
  run jq -r '.entries | length' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "1" ]
  run jq -r '.entries[0].id' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "imp-0001" ]
  run jq -r '.entries[0].sprint_id' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "sprint-001" ]
  run jq -r '.entries[0].status' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "active" ]
  run jq -r '.entries[0].archived_at' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "null" ]
  run jq -r '.last_consolidation_sprint' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "null" ]
}

@test "append-improvement: second append increments id to imp-0002" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-001 --description "first"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-002 --description "second"
  [ "$status" -eq 0 ]
  [ "$output" = "imp-0002" ]
  run jq -r '.entries | length' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "2" ]
  run jq -r '.entries[-1].sprint_id' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "sprint-002" ]
}

@test "append-improvement: optional --dec-id is stored when supplied" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-003 --description "Tied to PO decision" \
    --dec-id dec-0042
  [ "$status" -eq 0 ]
  run jq -r '.entries[0].dec_id' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "dec-0042" ]
}

@test "append-improvement: dec_id is absent when --dec-id not passed" {
  env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-001 --description "no link"
  run jq -e '.entries[0] | has("dec_id") | not' "$TEST_TMP/.scrum/improvements.json"
  [ "$status" -eq 0 ]
}

@test "append-improvement: appends to a legacy file carrying a deprecated category field" {
  # Regression: pre-wrapper improvements.json files tagged entries with a
  # `category` field. append-improvement.sh re-validates the WHOLE file on
  # every append, so a legacy entry must remain schema-valid (the schema
  # tolerates `category` for backward compat).
  cat > .scrum/improvements.json <<'JSON'
{"entries":[{"id":"imp-0001","sprint_id":"sprint-001","description":"legacy item","status":"active","created_at":"2026-01-01T00:00:00Z","category":"process"}],"last_consolidation_sprint":null}
JSON
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-002 --description "new item after legacy"
  [ "$status" -eq 0 ]
  [ "$output" = "imp-0002" ]
  run jq -r '.entries | length' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "2" ]
  # The legacy category survives untouched.
  run jq -r '.entries[0].category' "$TEST_TMP/.scrum/improvements.json"
  [ "$output" = "process" ]
}

@test "append-improvement: rejects missing --sprint" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --description "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--sprint required"* ]]
}

@test "append-improvement: rejects missing --description" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" --sprint sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"--description required"* ]]
}

@test "append-improvement: rejects bad --sprint pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint bogus --description "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --sprint"* ]]
}

@test "append-improvement: rejects bad --dec-id pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-001 --description "x" --dec-id dec-1
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --dec-id"* ]]
}

@test "append-improvement: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT" \
    --sprint sprint-001 --description "x" --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}
