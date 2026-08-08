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
    --audit-identity "notify-order::send-before-write" --audit-severity high
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
    --audit-identity "laneB/participation_job.py::is_open_for" --audit-severity high
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: --audit-identity rejects a one-part key" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F4:High] one part" \
    --audit-identity "notify-order" --audit-severity high
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: --audit-identity rejects upper case (normalization)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F5:High] upper case" \
    --audit-identity "Notify-Order::Send-Before-Write" --audit-severity high
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-identity"* ]]
}

@test "add-backlog-item: --audit-severity persists lowercase on the item" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F1:Critical] spec cannot be met" \
    --audit-identity "notify-order::send-before-write" --audit-severity critical
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].audit_severity' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "critical" ]
}

@test "add-backlog-item: audit-titled PBI without --audit-severity is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F2:High] no severity flag" \
    --audit-identity "notify-order::send-before-write"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--audit-severity required"* ]]
}

@test "add-backlog-item: --audit-severity medium is rejected (Medium was abolished)" {
  # Pins the 4→3 level change: a wrapper that still accepted Medium would let
  # the retired level back in through the one writer that mints audit PBIs.
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F3:Medium] retired level" \
    --audit-identity "notify-order::send-before-write" --audit-severity medium
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --audit-severity"* ]]
}

@test "add-backlog-item: title severity disagreeing with the field is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F4:Critical] drifted" \
    --audit-identity "notify-order::send-before-write" --audit-severity high
  [ "$status" -eq 64 ]
  [[ "$output" == *"Critical"* ]]
  [[ "$output" == *"high"* ]]
}

@test "add-backlog-item: Title-case title with lowercase field is the happy path" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F5:Critical] agrees" \
    --audit-identity "notify-order::send-before-write" --audit-severity critical
  [ "$status" -eq 0 ]
}

@test "add-backlog-item: audit title with no severity suffix is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F1] no suffix" \
    --audit-identity "notify-order::send-before-write" --audit-severity high
  [ "$status" -eq 64 ]
  [[ "$output" == *"no severity suffix"* ]]
}

@test "add-backlog-item: non-audit PBI may omit --audit-severity (field is null)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature"
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].audit_severity' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "null" ]
}

@test "add-backlog-item: non-audit PBI may carry --audit-severity (inert, mirrors --audit-identity)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature" --audit-severity low
  [ "$status" -eq 0 ]
  run jq -r '.items[-1].audit_severity' "$TEST_TMP/.scrum/backlog.json"
  [ "$output" = "low" ]
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
