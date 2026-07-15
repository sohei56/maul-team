#!/usr/bin/env bats
# tests/unit/scrum-state/test_update-pbi-state.bats — variadic field=value setter for PBI pipeline state.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/upd-pbi-state.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/upd-pbi-state.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{
  "pbi_id": "pbi-001",
  "design_round": 0,
  "impl_round": 0,
  "design_status": "pending",
  "impl_status": "pending",
  "ut_status": "pending",
  "coverage_status": "pending",
  "escalation_reason": null,
  "started_at": "2026-05-02T12:00:00Z",
  "updated_at": "2026-05-02T12:00:00Z"
}
EOF
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "update-pbi-state: bumps design_round" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 1
  [ "$status" -eq 0 ]
  run jq -r '.design_round' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "1" ]
}

@test "update-pbi-state: variadic — sets multiple fields atomically" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" \
    pbi-001 design_round 2 design_status in_review impl_round 1 impl_status pending
  [ "$status" -eq 0 ]
  run jq -r '"\(.design_round)/\(.design_status)/\(.impl_round)/\(.impl_status)"' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "2/in_review/1/pending" ]
}

@test "update-pbi-state: sets escalation_reason" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason stagnation
  [ "$status" -eq 0 ]
  run jq -r '.escalation_reason' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "stagnation" ]
}

@test "update-pbi-state: clears escalation_reason via null" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason stagnation
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason null
  [ "$status" -eq 0 ]
  run jq -r '.escalation_reason' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "null" ]
}

@test "update-pbi-state: accepts merge_conflict / merge_artifact_missing / merge_regression escalation_reason" {
  for r in merge_conflict merge_artifact_missing merge_regression; do
    run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason "$r"
    [ "$status" -eq 0 ]
    run jq -r '.escalation_reason' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
    [ "$output" = "$r" ]
  done
}

@test "update-pbi-state: accepts reviewer_unavailable / stale_review_snapshot escalation_reason" {
  for r in reviewer_unavailable stale_review_snapshot; do
    run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason "$r"
    [ "$status" -eq 0 ]
    run jq -r '.escalation_reason' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
    [ "$output" = "$r" ]
  done
}

@test "update-pbi-state: rejects unknown escalation_reason" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 escalation_reason solar_flare
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad escalation_reason"* ]]
}

@test "update-pbi-state: rejects phase as a writable field (phase no longer exists in schema)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase design
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "update-pbi-state: rejects unknown field (typo guard)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 wibble 1
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "update-pbi-state: rejects bad enum value" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_status frobnicating
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad design_status"* ]]
}

@test "update-pbi-state: rejects non-integer for round" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round abc
  [ "$status" -eq 64 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "update-pbi-state: accepts design_round 5 (design bound)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 5
  [ "$status" -eq 0 ]
  run jq -r '.design_round' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "5" ]
}

@test "update-pbi-state: rejects design_round 6 (over design bound; remediation latch is impl-only)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 6
  [ "$status" -eq 64 ]
  [[ "$output" == *"<= 5"* ]]
}

@test "update-pbi-state: accepts impl_round 6 (impl bound: +1 remediation Round)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 impl_round 6
  [ "$status" -eq 0 ]
  run jq -r '.impl_round' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "6" ]
}

@test "update-pbi-state: rejects impl_round 7 (over impl bound)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 impl_round 7
  [ "$status" -eq 64 ]
  [[ "$output" == *"<= 6"* ]]
}

@test "update-pbi-state: pbi-state.schema caps design_round at 5 and impl_round at 6" {
  run jq -e '
    (.properties.design_round.maximum == 5) and
    (.properties.impl_round.maximum == 6)
  ' "$TEST_TMP/docs/contracts/scrum-state/pbi-state.schema.json"
  [ "$status" -eq 0 ]
}

@test "update-pbi-state: rejects bad pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" "BAD ID" design_round 1
  [ "$status" -eq 64 ]
}

@test "update-pbi-state: fails when pbi state file missing" {
  rm -f "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 1
  [ "$status" -eq 67 ]
  [[ "$output" == *"E_FILE_MISSING"* ]]
}

@test "update-pbi-state: rejects odd arg count" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 1 impl_round
  [ "$status" -eq 64 ]
  [[ "$output" == *"paired"* ]]
}

@test "update-pbi-state: requires at least 3 args" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round
  [ "$status" -eq 64 ]
}

@test "update-pbi-state: stamps updated_at automatically" {
  before="$(jq -r '.updated_at' "$TEST_TMP/.scrum/pbi/pbi-001/state.json")"
  sleep 1
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 design_round 1
  after="$(jq -r '.updated_at' "$TEST_TMP/.scrum/pbi/pbi-001/state.json")"
  [ "$before" != "$after" ]
}

@test "update-pbi-state: sets branch / worktree / base_sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" \
    pbi-001 branch pbi/pbi-001 worktree .scrum/worktrees/pbi-001 base_sha abcdef0123456789
  [ "$status" -eq 0 ]
  run jq -r '"\(.branch)|\(.worktree)|\(.base_sha)"' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "pbi/pbi-001|.scrum/worktrees/pbi-001|abcdef0123456789" ]
}

@test "update-pbi-state: sets head_sha / merged_sha / merge_failure_count" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" \
    pbi-001 head_sha 1234567 merged_sha abcdef0 merge_failure_count 2
  [ "$status" -eq 0 ]
}

@test "update-pbi-state: sets websearch_attempted true/false" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 websearch_attempted true
  [ "$status" -eq 0 ]
  run jq -r '.websearch_attempted' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "true" ]
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 websearch_attempted false
  [ "$status" -eq 0 ]
  run jq -r '.websearch_attempted' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "false" ]
}

@test "update-pbi-state: rejects non-boolean websearch_attempted" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 websearch_attempted yes
  [ "$status" -eq 64 ]
  [[ "$output" == *"websearch_attempted must be true or false"* ]]
}

@test "update-pbi-state: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 head_sha NOT_A_SHA
  [ "$status" -ne 0 ]
}

@test "update-pbi-state: rejects bad branch name" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 branch main
  [ "$status" -ne 0 ]
}
