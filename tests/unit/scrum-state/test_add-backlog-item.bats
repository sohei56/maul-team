#!/usr/bin/env bats
# tests/unit/scrum-state/test_add-backlog-item.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/add-backlog-item.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/add-backlog-item.XXXXXX")"
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

@test "add-backlog-item: creates draft PBI with title, allocates next id from next_pbi_id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "New leftover"
  [ "$status" -eq 0 ]
  [ "$output" = "pbi-002" ]
  run jq -r '.items[] | select(.id=="pbi-002") | .status' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "draft" ]
  run jq -r '.items[] | select(.id=="pbi-002") | .title' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "New leftover" ]
  run jq -c '.items[] | select(.id=="pbi-002") | .demo_plan' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "null" ]
  run jq -r '.next_pbi_id' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "3" ]
}

@test "add-backlog-item: --description, --ac (repeatable), --ux-change persisted" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Carry-over: User Mgmt logout edge case" \
    --description "Continuation of pbi-001 — logout button race condition" \
    --ac "Logout while in-flight request resolves cleanly" \
    --ac "No double-logout toast" \
    --ux-change
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].description' "$TEST_TMP/.scrum/backlog.json"
  [[ "$output" == *"pbi-001"* ]]
  run jq -r '.items[-1].acceptance_criteria | length' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "2" ]
  run jq -r '.items[-1].ux_change' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "true" ]
}

@test "add-backlog-item: --parent sets parent_pbi_id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Child split" \
    --parent pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].parent_pbi_id' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "pbi-001" ]
}

@test "add-backlog-item: --parent rejects bad pbi-id format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "X" \
    --parent "not-a-pbi"
  [ "$status" -eq 64 ]
}

@test "add-backlog-item: --title is required" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --description "no title"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--title required"* ]]
}

@test "add-backlog-item: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "X" --bogus value
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "add-backlog-item: falls back to max(items[].id)+1 when next_pbi_id missing" {
  jq 'del(.next_pbi_id) | .items[0].id = "pbi-007"' "$TEST_TMP/.scrum/backlog.json" > tmp.json
  mv tmp.json "$TEST_TMP/.scrum/backlog.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "After fallback"
  [ "$status" -eq 0 ]
  [ "$output" = "pbi-008" ]
  run jq -r '.next_pbi_id' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "9" ]
}

@test "add-backlog-item: rejects when title is empty string (schema minLength)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title ""
  [ "$status" -eq 64 ]
}

@test "add-backlog-item: handles content with quotes/newlines safely" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title 'Defect: "Save" button does not commit' \
    --description $'Line one\nLine two with "quotes"'
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].title' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = 'Defect: "Save" button does not commit' ]
}

@test "add-backlog-item: missing backlog.json -> E_FILE_MISSING (67)" {
  rm "$TEST_TMP/.scrum/backlog.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "X"
  [ "$status" -eq 67 ]
}

@test "add-backlog-item: defaults kind to 'code' when --kind absent" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Default kind"
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].kind' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "code" ]
}

@test "add-backlog-item: --kind docs persists kind=docs" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Docs PBI" --kind docs
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].kind' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "docs" ]
}

@test "add-backlog-item: --kind code persists kind=code (explicit)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Code PBI" --kind code
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].kind' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "code" ]
}

@test "add-backlog-item: --kind rejects unknown value" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "X" --kind bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --kind"* ]]
}

@test "add-backlog-item: --audit-identity persists on the item" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F1:High] notify order inverted" \
    --audit-identity "notify-order::send-before-write"
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].audit_identity' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "notify-order::send-before-write" ]
}

@test "add-backlog-item: audit-titled PBI without --audit-identity is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F2:High] missing key"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--audit-identity required"* ]]
}

@test "add-backlog-item: non-audit PBI may omit --audit-identity (field is null)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature"
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].audit_identity' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "null" ]
}

@test "add-backlog-item: --audit-identity rejects a path-shaped key" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F3:High] path key" \
    --audit-identity "laneB/participation_job.py::is_open_for"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: --audit-identity rejects a one-part key" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F4:High] one part" \
    --audit-identity "notify-order"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: --audit-identity rejects upper case (normalization)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F5:High] upper case" \
    --audit-identity "Notify-Order::Send-Before-Write"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: id grows past pbi-999 (pbi-1000, no truncation)" {
  jq '.next_pbi_id = 1000' .scrum/backlog.json > backlog.tmp && mv backlog.tmp .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "Thousandth PBI"
  [ "$status" -eq 0 ]
  [ "$output" = "pbi-1000" ]
  run jq -r '.next_pbi_id' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "1001" ]
}

@test "add-backlog-item: fallback max-scan parses 4-digit ids" {
  jq 'del(.next_pbi_id) | .items[0].id = "pbi-1000"' .scrum/backlog.json > backlog.tmp \
    && mv backlog.tmp .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "After rollover"
  [ "$status" -eq 0 ]
  [ "$output" = "pbi-1001" ]
}
