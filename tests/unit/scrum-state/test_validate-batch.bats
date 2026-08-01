#!/usr/bin/env bats
# test_validate-batch.bats — _validate_batch_against_schema in lib/atomic.sh:
# many files, one schema, ONE validator process. Contract is boolean only
# (0 = every file valid), so migrate-state.sh can use it as the fast path and
# fall back to per-file checks for attribution.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json"
  TEST_TMP="$(mktemp -d /tmp/claude/validate-batch.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/validate-batch.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  cp "$PROJECT_ROOT/tests/fixtures/valid-pbi-state-docs-skipped.json" a.json
  cp a.json b.json
  cp a.json c.json
  echo '{"bogus": 1}' > bad.json
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/scrum/lib/errors.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/scrum/lib/atomic.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "batch: all-valid set returns 0" {
  run _validate_batch_against_schema "$SCHEMA" a.json b.json c.json
  [ "$status" -eq 0 ]
}

@test "batch: one invalid file fails the whole set" {
  run _validate_batch_against_schema "$SCHEMA" a.json bad.json c.json
  [ "$status" -ne 0 ]
}

@test "batch: invalid file in last position is still caught" {
  run _validate_batch_against_schema "$SCHEMA" a.json b.json bad.json
  [ "$status" -ne 0 ]
}

@test "batch: no files is a clean no-op" {
  run _validate_batch_against_schema "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "batch: single file behaves like the per-file helper" {
  run _validate_batch_against_schema "$SCHEMA" a.json
  [ "$status" -eq 0 ]
  run _validate_batch_against_schema "$SCHEMA" bad.json
  [ "$status" -ne 0 ]
}

@test "batch: unknown validator override is rejected, not silently passed" {
  SCRUM_VALIDATOR_OVERRIDE=nope
  unset _SCRUM_VALIDATOR_RUNNER
  run _validate_batch_against_schema "$SCHEMA" a.json
  [ "$status" -ne 0 ]
}

# The suite pins jsonschema-cli for determinism; this exercises the second
# batch branch when the python module happens to be installed. ajv (the
# auto-detected default on any machine with npx) and check-jsonschema are
# structurally identical — one process, many instance paths.
@test "batch: python runner agrees with the pinned runner" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python jsonschema module not installed"
  SCRUM_VALIDATOR_OVERRIDE=python
  unset _SCRUM_VALIDATOR_RUNNER
  run _validate_batch_against_schema "$SCHEMA" a.json b.json c.json
  [ "$status" -eq 0 ]
  run _validate_batch_against_schema "$SCHEMA" a.json bad.json c.json
  [ "$status" -ne 0 ]
  # python is the one runner that names the offending path itself.
  [[ "$output" == *"bad.json"* ]]
}

@test "runner probe is memoized after the first call" {
  unset _SCRUM_VALIDATOR_RUNNER
  _scrum_validator_runner >/dev/null
  [ "$_SCRUM_VALIDATOR_RUNNER" = "jsonschema-cli" ]
}
