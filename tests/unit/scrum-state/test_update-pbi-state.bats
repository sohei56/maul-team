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
  "phase": "design",
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

@test "update-pbi-state: escalates with reason" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase escalated escalation_reason stagnation
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "escalated" ]
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

@test "update-pbi-state: rejects bad pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" "BAD ID" phase design
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

@test "update-pbi-state: accepts ready_to_merge phase" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase ready_to_merge
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "ready_to_merge" ]
}

@test "update-pbi-state: accepts merged phase" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase merged
  [ "$status" -eq 0 ]
}

@test "update-pbi-state: accepts merge_conflict / merge_artifact_missing / merge_regression" {
  for p in merge_conflict merge_artifact_missing merge_regression; do
    run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase "$p"
    [ "$status" -eq 0 ]
  done
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

@test "update-pbi-state: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 head_sha NOT_A_SHA
  [ "$status" -ne 0 ]
}

@test "update-pbi-state: rejects bad branch name" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 branch main
  [ "$status" -ne 0 ]
}
