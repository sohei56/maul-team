#!/usr/bin/env bats
# tests/unit/scrum-state/test_update-backlog-status.bats —
# 12-value status enum is the sole SSOT; the wrapper accepts every value.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/upd-backlog-status.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/upd-backlog-status.XXXXXX")"
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

backlog_status() {
  jq -r --arg id "$1" '.items[] | select(.id==$id).status' "$TEST_TMP/.scrum/backlog.json"
}

@test "update-backlog-status: accepts draft" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 draft
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "draft" ]
}

@test "update-backlog-status: accepts refined" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 refined
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "refined" ]
}

@test "update-backlog-status: accepts in_progress_design (Dev-managed)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_design
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "in_progress_design" ]
}

@test "update-backlog-status: accepts in_progress_impl" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_impl
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "in_progress_impl" ]
}

@test "update-backlog-status: accepts in_progress_pbi_review" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_pbi_review
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "in_progress_pbi_review" ]
}

@test "update-backlog-status: accepts in_progress_ut_run" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_ut_run
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "in_progress_ut_run" ]
}

@test "update-backlog-status: accepts in_progress_merge" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_merge
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "in_progress_merge" ]
}

@test "update-backlog-status: accepts awaiting_cross_review" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 awaiting_cross_review
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "awaiting_cross_review" ]
}

@test "update-backlog-status: accepts cross_review" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 cross_review
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "cross_review" ]
}

@test "update-backlog-status: accepts escalated" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 escalated
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "escalated" ]
}

@test "update-backlog-status: accepts blocked" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 blocked
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "blocked" ]
}

@test "update-backlog-status: accepts done" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 done
  [ "$status" -eq 0 ]
  [ "$(backlog_status pbi-001)" = "done" ]
}

@test "update-backlog-status: rejects legacy in_progress (no longer in enum)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad status"* ]]
}

@test "update-backlog-status: rejects legacy review (no longer in enum)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 review
  [ "$status" -eq 64 ]
}

@test "update-backlog-status: rejects bad status" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 wibble
  [ "$status" -eq 64 ]
  [[ "$output" == *"E_INVALID_ARG"* ]]
}

@test "update-backlog-status: rejects bad pbi-id format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" "BAD ID" refined
  [ "$status" -eq 64 ]
}

@test "update-backlog-status: rejects nonexistent pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-999 refined
  [ "$status" -eq 64 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"E_INVALID_ARG"* ]]
}

@test "update-backlog-status: requires exactly two args" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001
  [ "$status" -eq 64 ]
}
