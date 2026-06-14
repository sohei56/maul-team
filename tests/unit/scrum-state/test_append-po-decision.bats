#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-po-decision.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-po.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-po.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/po-decisions.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/append-po-decision.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-po-decision: initial append creates file and assigns dec-0001" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind sprint_goal_approval --decision approve \
    --rationale "Goal is realistic for capacity"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.scrum/po/decisions.json" ]
  run jq -r '.decisions | length' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "1" ]
  run jq -r '.decisions[0].id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "dec-0001" ]
  run jq -r '.decisions[0].sprint_id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "null" ]
  run jq -r '.decisions[0].pbi_id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "null" ]
  run jq -r '.decisions[0].assumption' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "false" ]
}

@test "append-po-decision: second append increments id to dec-0002" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind sprint_goal_approval --decision approve --rationale "ok"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision "remove pbi-009" --rationale "out of scope"
  [ "$status" -eq 0 ]
  run jq -r '.decisions[-1].id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "dec-0002" ]
  run jq -r '.decisions | length' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "2" ]
}

@test "append-po-decision: stores all optional fields incl. evidence and assumption" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind demo_acceptance --decision accept \
    --rationale "All ACs verified" \
    --sprint sprint-1 --pbi pbi-001 \
    --request "Approve demo of pbi-001" \
    --evidence "demos/pbi-001.md" --evidence "screenshots/login.png" \
    --assumption
  [ "$status" -eq 0 ]
  run jq -r '.decisions[0].sprint_id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "sprint-1" ]
  run jq -r '.decisions[0].pbi_id' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "pbi-001" ]
  run jq -r '.decisions[0].evidence | length' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "2" ]
  run jq -r '.decisions[0].evidence[1]' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "screenshots/login.png" ]
  run jq -r '.decisions[0].assumption' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "true" ]
}

@test "append-po-decision: rejects missing --kind" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --decision x --rationale y
  [ "$status" -eq 64 ]
  [[ "$output" == *"--kind required"* ]]
}

@test "append-po-decision: rejects missing --decision" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --rationale y
  [ "$status" -eq 64 ]
  [[ "$output" == *"--decision required"* ]]
}

@test "append-po-decision: rejects missing --rationale" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision x
  [ "$status" -eq 64 ]
  [[ "$output" == *"--rationale required"* ]]
}

@test "append-po-decision: rejects bad --kind" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind frobnicate --decision x --rationale y
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --kind"* ]]
}

@test "append-po-decision: accepts sprint_continuation kind" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind sprint_continuation --decision "choice:next_sprint" \
    --sprint sprint-1 \
    --rationale "Product Goal not met; 5 refined PBIs remain"
  [ "$status" -eq 0 ]
  run jq -r '.decisions[-1].kind' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "sprint_continuation" ]
  run jq -r '.decisions[-1].decision' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "choice:next_sprint" ]
}

@test "append-po-decision: rejects bad --pbi format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision x --rationale y --pbi WIBBLE
  [ "$status" -eq 64 ]
}

@test "append-po-decision: rejects bad --sprint format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision x --rationale y --sprint 1
  [ "$status" -eq 64 ]
}

@test "append-po-decision: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --bogus xx --kind scope_change --decision x --rationale y
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "append-po-decision: demo_acceptance without evidence is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind demo_acceptance --decision accept --rationale "looks good"
  [ "$status" -eq 64 ]
  [[ "$output" == *"evidence required"* ]]
}

@test "append-po-decision: uat_item without evidence is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind uat_item --decision accept --rationale ok
  [ "$status" -eq 64 ]
  [[ "$output" == *"evidence required"* ]]
}

@test "append-po-decision: release_decision without evidence is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision no_go --rationale "tests red"
  [ "$status" -eq 64 ]
  [[ "$output" == *"evidence required"* ]]
}

@test "append-po-decision: release_decision=go without test-results.json is rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision go --rationale "ship it" \
    --evidence "reports/release.md"
  [ "$status" -eq 64 ]
  [[ "$output" == *"test-results.json"* ]]
}

@test "append-po-decision: release_decision=go with failed tests is rejected" {
  printf '%s\n' '{"overall_status":"failed"}' > "$TEST_TMP/.scrum/test-results.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision go --rationale "ship it" \
    --evidence "reports/release.md"
  [ "$status" -eq 64 ]
  [[ "$output" == *"passed"* ]]
}

@test "append-po-decision: release_decision=go with passed tests succeeds" {
  printf '%s\n' '{"overall_status":"passed"}' > "$TEST_TMP/.scrum/test-results.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision go --rationale "ship it" \
    --evidence "reports/release.md"
  [ "$status" -eq 0 ]
  run jq -r '.decisions[0].kind' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "release_decision" ]
}

@test "append-po-decision: release_decision=go with passed_with_skips tests succeeds" {
  printf '%s\n' '{"overall_status":"passed_with_skips"}' > "$TEST_TMP/.scrum/test-results.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision go --rationale "ship despite skips" \
    --evidence "reports/release.md"
  [ "$status" -eq 0 ]
}

@test "append-po-decision: release_decision=no_go does not require green tests" {
  # no_go path is allowed even without test-results.json (we are abstaining,
  # not approving release). Evidence is still required (approval-class kind).
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind release_decision --decision no_go --rationale "regression detected" \
    --evidence "reports/regression-log.md"
  [ "$status" -eq 0 ]
  run jq -r '.decisions[0].decision' "$TEST_TMP/.scrum/po/decisions.json"
  [ "$output" = "no_go" ]
}

@test "append-po-decision: escapes special characters in rationale" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision keep \
    --rationale 'has "quotes" and \backslash and
 newlines'
  [ "$status" -eq 0 ]
  run jq -r '.decisions[0].rationale' "$TEST_TMP/.scrum/po/decisions.json"
  [[ "$output" == *'"quotes"'* ]]
}

@test "append-po-decision: emits assigned id on stdout" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" \
    --kind scope_change --decision keep --rationale ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"dec-0001"* ]]
}
