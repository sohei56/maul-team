#!/usr/bin/env bats
# tests/unit/test_contract_schemas.bats —
# The four top-level contracts under docs/contracts/ (coverage-rN,
# test-results-rN, pragma-audit-rN, pbi-pipeline-envelope) are deployed to
# every target project and are read by agents as prose, but until this file
# NOTHING validated against them: no script, no hook, no test. Their failure
# mode is known and acknowledged — `rules/scrum-context.md` says "Missing or
# malformed envelopes break the pipeline orchestrator's parser" — yet nothing
# enforced the contract at write time.
#
# These are LLM-authored artifacts, so the schemas cannot be enforced at
# runtime the way `.scrum/*.json` is (which goes through wrappers). What CAN
# be enforced is that the schemas themselves stay coherent and keep their
# teeth: each valid fixture must pass, and each invalid fixture must be
# REJECTED. A schema that accepts everything is worse than no schema, because
# it reads as enforcement.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CONTRACTS="$PROJECT_ROOT/docs/contracts"
  FIX="$PROJECT_ROOT/tests/fixtures/contracts"
}

# Validate through the SAME path production uses (scripts/scrum/lib/atomic.sh)
# rather than hardcoding one validator's CLI — the runner is resolved by
# lib/check-validator.sh and differs across machines.
# Usage: VALIDATE <instance.json> <schema.json>
VALIDATE() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli bash -c '
    source "$1/scripts/scrum/lib/errors.sh"
    source "$1/scripts/scrum/lib/atomic.sh"
    _validate_against_schema "$2" "$3"
  ' _ "$PROJECT_ROOT" "$1" "$2"
}

# --- The schemas are well-formed -------------------------------------------

@test "contract schemas: all four are parseable JSON" {
  local s
  for s in coverage-rN pragma-audit-rN test-results-rN pbi-pipeline-envelope; do
    run jq empty "$CONTRACTS/$s.schema.json"
    [ "$status" -eq 0 ]
  done
}

@test "contract schemas: all four declare a \$schema and a title" {
  local s
  for s in coverage-rN pragma-audit-rN test-results-rN pbi-pipeline-envelope; do
    run jq -e 'has("$schema") and has("title")' "$CONTRACTS/$s.schema.json"
    [ "$status" -eq 0 ]
  done
}

# --- Valid fixtures must PASS ----------------------------------------------

@test "envelope: a well-formed sub-agent envelope validates" {
  run VALIDATE "$FIX/valid-envelope.json" "$CONTRACTS/pbi-pipeline-envelope.schema.json"
  [ "$status" -eq 0 ]
}

@test "coverage-rN: a well-formed coverage report validates" {
  run VALIDATE "$FIX/valid-coverage-rN.json" "$CONTRACTS/coverage-rN.schema.json"
  [ "$status" -eq 0 ]
}

@test "test-results-rN: a well-formed test-results report validates" {
  run VALIDATE "$FIX/valid-test-results-rN.json" "$CONTRACTS/test-results-rN.schema.json"
  [ "$status" -eq 0 ]
}

@test "pragma-audit-rN: a well-formed pragma audit validates" {
  run VALIDATE "$FIX/valid-pragma-audit-rN.json" "$CONTRACTS/pragma-audit-rN.schema.json"
  [ "$status" -eq 0 ]
}

# --- Invalid fixtures must be REJECTED (the schemas have teeth) -------------

@test "envelope: a criterion_key outside the enum is rejected" {
  run VALIDATE "$FIX/invalid-envelope-bad-criterion-key.json" "$CONTRACTS/pbi-pipeline-envelope.schema.json"
  [ "$status" -ne 0 ]
}

@test "envelope: a signature not matching file:start-end:key is rejected" {
  # The signature pattern drives stagnation/divergence dedup in the
  # termination gates; a prose signature silently degrades gate accuracy.
  run VALIDATE "$FIX/invalid-envelope-bad-signature.json" "$CONTRACTS/pbi-pipeline-envelope.schema.json"
  [ "$status" -ne 0 ]
}

@test "coverage-rN: c1 without 'supported' is rejected" {
  # The coverage gate branches on .totals.c1.supported before comparing the
  # C1 threshold; absent, a partial-C1 language would be graded as if C1 were
  # measured.
  run VALIDATE "$FIX/invalid-coverage-rN-missing-c1-supported.json" "$CONTRACTS/coverage-rN.schema.json"
  [ "$status" -ne 0 ]
}

@test "test-results-rN: a failure type outside the enum is rejected" {
  run VALIDATE "$FIX/invalid-test-results-rN-bad-failure-type.json" "$CONTRACTS/test-results-rN.schema.json"
  [ "$status" -ne 0 ]
}

@test "pragma-audit-rN: a reason_source outside the enum is rejected" {
  # evaluate_pass() checks `all(.reason_source != "missing")`; an unrecognised
  # value would slip past that test and read as justified.
  run VALIDATE "$FIX/invalid-pragma-audit-rN-bad-reason-source.json" "$CONTRACTS/pragma-audit-rN.schema.json"
  [ "$status" -ne 0 ]
}

# --- Drift guard: reviewer vocabularies ⊆ the envelope enum -----------------

# Extract the comma-separated `criterion_key` enum a reviewer agent declares.
# Format (stable across all three codex reviewers):
#   `criterion_key` enum (<stage> review): key_a, key_b,
#   key_c.
_reviewer_keys() {
  awk '
    /`criterion_key` enum/ { grab = 1 }
    grab { buf = buf " " $0 }
    grab && /\.[[:space:]]*$/ { print buf; exit }
  ' "$1" \
    | sed 's/.*review)://' \
    | tr ',' '\n' \
    | tr -d '. ' \
    | grep -E '^[a-z_]+$'
}

@test "envelope enum covers every criterion_key the codex reviewers declare" {
  # Regression guard for 1b2d9aa: `missing_library_spec` was emitted by
  # codex-design-reviewer but absent from the envelope enum, so a conforming
  # finding failed its own contract. Nothing caught it until an audit did.
  local schema_keys agent key missing=""
  schema_keys="$(jq -r '.properties.findings.items.properties.criterion_key.enum[]' \
    "$CONTRACTS/pbi-pipeline-envelope.schema.json")"

  for agent in codex-design-reviewer codex-impl-reviewer codex-ut-reviewer; do
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if ! printf '%s\n' "$schema_keys" | grep -qx "$key"; then
        missing="$missing $agent:$key"
      fi
    done <<< "$(_reviewer_keys "$PROJECT_ROOT/agents/$agent.md")"
  done

  [ -z "$missing" ] || {
    echo "criterion_key values declared by a reviewer but missing from the envelope enum:$missing"
    return 1
  }
}

@test "the reviewer enum extractor actually finds keys (guards against a silent no-op)" {
  # If the agent-file format changes, _reviewer_keys could return nothing and
  # the drift guard above would pass vacuously. Pin the expected counts.
  local n
  n="$(_reviewer_keys "$PROJECT_ROOT/agents/codex-design-reviewer.md" | grep -c .)"
  [ "$n" -ge 6 ]
  n="$(_reviewer_keys "$PROJECT_ROOT/agents/codex-impl-reviewer.md" | grep -c .)"
  [ "$n" -ge 6 ]
  n="$(_reviewer_keys "$PROJECT_ROOT/agents/codex-ut-reviewer.md" | grep -c .)"
  [ "$n" -ge 5 ]
}
