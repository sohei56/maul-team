#!/usr/bin/env bats
# tests/unit/scrum-state/test_init-pbi-state.bats — initialise per-PBI pipeline state.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/init-pbi-state.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/init-pbi-state.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "init-pbi-state: creates state.json with all required fields seeded" {
  run "$PROJECT_ROOT/scripts/scrum/init-pbi-state.sh" pbi-007
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.scrum/pbi/pbi-007/state.json" ]
  for sub in design impl ut metrics feedback; do
    [ -d "$TEST_TMP/.scrum/pbi/pbi-007/$sub" ]
  done
  run jq -r '.pbi_id, .design_round, .design_status, .escalation_reason' \
    "$TEST_TMP/.scrum/pbi/pbi-007/state.json"
  [ "${lines[0]}" = "pbi-007" ]
  [ "${lines[1]}" = "0" ]
  [ "${lines[2]}" = "pending" ]
  [ "${lines[3]}" = "null" ]
}

@test "init-pbi-state: idempotent on existing valid state.json" {
  "$PROJECT_ROOT/scripts/scrum/init-pbi-state.sh" pbi-007
  first_started_at="$(jq -r '.started_at' "$TEST_TMP/.scrum/pbi/pbi-007/state.json")"
  sleep 1
  run "$PROJECT_ROOT/scripts/scrum/init-pbi-state.sh" pbi-007
  [ "$status" -eq 0 ]
  second_started_at="$(jq -r '.started_at' "$TEST_TMP/.scrum/pbi/pbi-007/state.json")"
  [ "$first_started_at" = "$second_started_at" ]
}

@test "init-pbi-state: rejects bad pbi-id" {
  run "$PROJECT_ROOT/scripts/scrum/init-pbi-state.sh" not-a-pbi
  [ "$status" -ne 0 ]
}

@test "init-pbi-state: rejects existing state.json that violates schema" {
  mkdir -p .scrum/pbi/pbi-007
  echo '{"pbi_id": "pbi-007"}' > .scrum/pbi/pbi-007/state.json
  run "$PROJECT_ROOT/scripts/scrum/init-pbi-state.sh" pbi-007
  [ "$status" -ne 0 ]
}
