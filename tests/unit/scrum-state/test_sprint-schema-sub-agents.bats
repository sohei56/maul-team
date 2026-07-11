#!/usr/bin/env bats
# test_sprint-schema-sub-agents.bats — sprint.schema.json typing of
# developers[].sub_agents as string[] (previously an untyped array).
# Exercises the real schema-validation path via _validate_against_schema,
# the same helper every scrum-state wrapper uses.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json"
  FIXTURES="$PROJECT_ROOT/tests/fixtures"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/scrum/lib/errors.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/scrum/lib/atomic.sh"
}

@test "sprint.schema: sub_agents items are typed as string" {
  run jq -e '.properties.developers.items.properties.sub_agents.items.type == "string"' "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "sprint.schema: valid fixture (string sub_agents) validates" {
  run _validate_against_schema "$FIXTURES/valid-sprint.json" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "sprint.schema: non-string sub_agents element is rejected" {
  run _validate_against_schema "$FIXTURES/invalid-sprint-sub-agents-nonstring.json" "$SCHEMA"
  [ "$status" -ne 0 ]
}
