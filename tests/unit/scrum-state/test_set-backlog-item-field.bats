#!/usr/bin/env bats
# tests/unit/scrum-state/test_set-backlog-item-field.bats —
# Schema-validated wrapper for non-status item fields (sprint_id,
# implementer_id, review_doc_path, catalog_targets).

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/set-backlog-field.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/set-backlog-field.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

field_value() {
  jq -c --arg id "$1" --arg f "$2" '.items[] | select(.id==$id) | .[$f]' "$TEST_TMP/.scrum/backlog.json"
}

@test "set-backlog-item-field: restamps updated_at on the mutated item" {
  before="$(jq -r '.items[] | select(.id=="pbi-001").updated_at' "$TEST_TMP/.scrum/backlog.json")"
  [ "$before" = "2026-03-01T12:00:00Z" ]
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 priority 5
  [ "$status" -eq 0 ]
  after="$(jq -r '.items[] | select(.id=="pbi-001").updated_at' "$TEST_TMP/.scrum/backlog.json")"
  [ "$after" != "$before" ]
  [[ "$after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # the field itself was still written
  [ "$(field_value pbi-001 priority)" = "5" ]
}

@test "set-backlog-item-field: sets sprint_id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 sprint_id sprint-007
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 sprint_id)" = '"sprint-007"' ]
}

@test "set-backlog-item-field: clears sprint_id via null" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 sprint_id null
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 sprint_id)" = "null" ]
}

@test "set-backlog-item-field: rejects bad sprint_id pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 sprint_id wibble
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad sprint_id"* ]]
}

@test "set-backlog-item-field: sets implementer_id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 implementer_id dev-002-s7
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 implementer_id)" = '"dev-002-s7"' ]
}

@test "set-backlog-item-field: rejects bad implementer_id pattern" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 implementer_id devOne
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad implementer_id"* ]]
}

@test "set-backlog-item-field: sets catalog_targets array" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 catalog_targets '["docs/design/specs/foo.md","docs/design/specs/bar.md"]'
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 catalog_targets)" = '["docs/design/specs/foo.md","docs/design/specs/bar.md"]' ]
}

@test "set-backlog-item-field: rejects catalog_targets non-array" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 catalog_targets '"docs/design/specs/foo.md"'
  [ "$status" -eq 64 ]
  [[ "$output" == *"array of strings"* ]]
}

@test "set-backlog-item-field: rejects catalog_targets bad json" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 catalog_targets 'not-json'
  [ "$status" -eq 64 ]
  [[ "$output" == *"valid JSON"* ]]
}

@test "set-backlog-item-field: rejects catalog_targets non-string element" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 catalog_targets '[1,2,3]'
  [ "$status" -eq 64 ]
  [[ "$output" == *"array of strings"* ]]
}

@test "set-backlog-item-field: sets review_doc_path" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 review_doc_path .scrum/reviews/pbi-001-review.md
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 review_doc_path)" = '".scrum/reviews/pbi-001-review.md"' ]
}

@test "set-backlog-item-field: clears review_doc_path via null" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 review_doc_path null
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 review_doc_path)" = "null" ]
}

@test "set-backlog-item-field: refuses status (use update-backlog-status.sh)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 status done
  [ "$status" -eq 64 ]
  [[ "$output" == *"update-backlog-status.sh"* ]]
}

@test "set-backlog-item-field: sets priority integer" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 priority 3
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 priority)" = "3" ]
}

@test "set-backlog-item-field: clears priority via null" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 priority null
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 priority)" = "null" ]
}

@test "set-backlog-item-field: rejects priority non-integer string" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 priority high
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad priority"* ]]
}

@test "set-backlog-item-field: rejects priority negative" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 priority -1
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad priority"* ]]
}

@test "set-backlog-item-field: rejects unknown field" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 wibble x
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "set-backlog-item-field: rejects bad pbi-id format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" "BAD ID" sprint_id sprint-001
  [ "$status" -eq 64 ]
}

@test "set-backlog-item-field: rejects nonexistent pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-999 sprint_id sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"not found"* ]]
}

@test "set-backlog-item-field: requires exactly three args" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 sprint_id
  [ "$status" -eq 64 ]
}

@test "set-backlog-item-field: sets kind=docs" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 kind docs
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 kind)" = '"docs"' ]
}

@test "set-backlog-item-field: sets kind=code (explicit)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 kind code
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 kind)" = '"code"' ]
}

@test "set-backlog-item-field: rejects bad kind value" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 kind bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad kind"* ]]
}

@test "set-backlog-item-field: sets demo_plan" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 demo_plan 'make run; curl -sf http://localhost:8080/healthz; observe "ok"'
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 demo_plan)" = '"make run; curl -sf http://localhost:8080/healthz; observe \"ok\""' ]
}

@test "set-backlog-item-field: clears demo_plan via null" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" pbi-001 demo_plan null
  [ "$status" -eq 0 ]
  [ "$(field_value pbi-001 demo_plan)" = "null" ]
}
