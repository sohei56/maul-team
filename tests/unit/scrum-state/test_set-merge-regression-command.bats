#!/usr/bin/env bats
# tests/unit/scrum-state/test_set-merge-regression-command.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/set-merge-reg.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/set-merge-reg.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/config.schema.json" docs/contracts/scrum-state/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/set-merge-regression-command.sh"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

@test "set-merge-regression: creates config.json when absent and sets command" {
  [ ! -f .scrum/config.json ]
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" "pytest -q"
  [ "$status" -eq 0 ]
  [ -f .scrum/config.json ]
  run jq -r '.merge_regression.command' .scrum/config.json
  [ "$output" = "pytest -q" ]
  run jq -r '.merge_regression.accepted_none' .scrum/config.json
  [ "$output" = "false" ]
}

@test "set-merge-regression: --none records accepted_none=true and null command" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" --none
  [ "$status" -eq 0 ]
  run jq -r '.merge_regression.command' .scrum/config.json
  [ "$output" = "null" ]
  run jq -r '.merge_regression.accepted_none' .scrum/config.json
  [ "$output" = "true" ]
}

@test "set-merge-regression: configuring after --none clears accepted_none" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" --none
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" "make test"
  [ "$status" -eq 0 ]
  run jq -r '.merge_regression.command' .scrum/config.json
  [ "$output" = "make test" ]
  run jq -r '.merge_regression.accepted_none' .scrum/config.json
  [ "$output" = "false" ]
}

@test "set-merge-regression: preserves unrelated config keys" {
  cat > .scrum/config.json <<'EOF'
{"po_mode":"agent","merge_regression":{"command":null,"other":"keep"}}
EOF
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" "go test ./..."
  [ "$status" -eq 0 ]
  run jq -r '.po_mode' .scrum/config.json
  [ "$output" = "agent" ]
  run jq -r '.merge_regression.other' .scrum/config.json
  [ "$output" = "keep" ]
  run jq -r '.merge_regression.command' .scrum/config.json
  [ "$output" = "go test ./..." ]
}

@test "set-merge-regression: command string with quotes is stored verbatim (no injection)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" 'bash -c "echo \"hi\""'
  [ "$status" -eq 0 ]
  run jq -r '.merge_regression.command' .scrum/config.json
  [ "$output" = 'bash -c "echo \"hi\""' ]
}

@test "set-merge-regression: empty command rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "non-empty"
}

@test "set-merge-regression: unknown flag rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" --nope
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown flag"
}

@test "set-merge-regression: missing argument rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "usage:"
}

@test "set-merge-regression: too many arguments rejected" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$SCRIPT" "pytest -q" extra
  [ "$status" -ne 0 ]
}
