#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-004-drop-pbi-state-phase.bats —
# One-shot migration that strips the legacy `phase` key from
# .scrum/pbi/<pbi-id>/state.json.
#
# Regression context: 001-legacy-to-ssot.sh deliberately skips per-PBI files,
# but pbi-state.schema.json is additionalProperties:false and migrate-state.sh
# validates every per-PBI file in its BLOCKING batch pass. A v1 file still
# carrying `phase` therefore hard-failed launch with no repair path.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-pbiphase.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-pbiphase.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

MIGRATION() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/migrations/004-drop-pbi-state-phase.sh" "$@"
}

# Validate through the SAME path production uses (lib/atomic.sh) rather than
# hardcoding one validator's CLI.
VALIDATE() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli bash -c '
    source "$1/scripts/scrum/lib/errors.sh"
    source "$1/scripts/scrum/lib/atomic.sh"
    _validate_against_schema "$2" "$3"
  ' _ "$PROJECT_ROOT" "$1" "docs/contracts/scrum-state/pbi-state.schema.json"
}

# v1 per-PBI state: carries the removed `phase` key.
_seed_legacy_pbi() {
  local id="$1" phase="$2"
  mkdir -p ".scrum/pbi/$id"
  jq -n --arg id "$id" --arg ph "$phase" '{
    pbi_id: $id,
    phase: $ph,
    design_round: 1,
    impl_round: 0,
    design_status: "pass",
    started_at: "2026-03-01T10:00:00Z",
    updated_at: "2026-03-01T10:00:00Z"
  }' > ".scrum/pbi/$id/state.json"
}

# v2 per-PBI state: no `phase`.
_seed_modern_pbi() {
  local id="$1"
  mkdir -p ".scrum/pbi/$id"
  jq -n --arg id "$id" '{
    pbi_id: $id,
    design_round: 2,
    impl_round: 1,
    design_status: "pass",
    impl_status: "in_review",
    started_at: "2026-03-02T10:00:00Z",
    updated_at: "2026-03-02T10:00:00Z"
  }' > ".scrum/pbi/$id/state.json"
}

@test "004-drop-pbi-state-phase: legacy file fails the schema before migrating (proves the launch-block)" {
  _seed_legacy_pbi pbi-001 design
  run VALIDATE .scrum/pbi/pbi-001/state.json
  [ "$status" -ne 0 ]
}

@test "004-drop-pbi-state-phase: strips phase from every per-PBI file that carries it" {
  _seed_legacy_pbi pbi-001 design
  _seed_legacy_pbi pbi-002 implementation
  _seed_modern_pbi pbi-003
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"stripped phase from 2 of 3 per-PBI state files"* ]]
  run jq -e 'has("phase")' .scrum/pbi/pbi-001/state.json
  [ "$status" -ne 0 ]
  run jq -e 'has("phase")' .scrum/pbi/pbi-002/state.json
  [ "$status" -ne 0 ]
}

@test "004-drop-pbi-state-phase: result validates against the current schema" {
  _seed_legacy_pbi pbi-001 design
  MIGRATION
  run VALIDATE .scrum/pbi/pbi-001/state.json
  [ "$status" -eq 0 ]
}

@test "004-drop-pbi-state-phase: preserves every other field" {
  _seed_legacy_pbi pbi-001 design
  MIGRATION
  run jq -r '"\(.pbi_id)|\(.design_round)|\(.impl_round)|\(.design_status)|\(.started_at)"' .scrum/pbi/pbi-001/state.json
  [ "$output" = "pbi-001|1|0|pass|2026-03-01T10:00:00Z" ]
}

@test "004-drop-pbi-state-phase: leaves an already-modern file byte-identical" {
  _seed_modern_pbi pbi-003
  HASH_BEFORE="$(shasum .scrum/pbi/pbi-003/state.json | awk '{print $1}')"
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  HASH_AFTER="$(shasum .scrum/pbi/pbi-003/state.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "004-drop-pbi-state-phase: idempotent (second run is no-op)" {
  _seed_legacy_pbi pbi-001 design
  MIGRATION
  HASH_BEFORE="$(shasum .scrum/pbi/pbi-001/state.json | awk '{print $1}')"
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  HASH_AFTER="$(shasum .scrum/pbi/pbi-001/state.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "004-drop-pbi-state-phase: --dry-run reports the plan without writing" {
  _seed_legacy_pbi pbi-001 design
  HASH_BEFORE="$(shasum .scrum/pbi/pbi-001/state.json | awk '{print $1}')"
  run MIGRATION --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would strip phase from 1 of 1 per-PBI state files"* ]]
  HASH_AFTER="$(shasum .scrum/pbi/pbi-001/state.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "004-drop-pbi-state-phase: clean no-op when .scrum/pbi missing (migration contract)" {
  rm -rf .scrum/pbi
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "004-drop-pbi-state-phase: clean no-op when .scrum/pbi is empty" {
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "004-drop-pbi-state-phase: does NOT swallow an unrelated unknown key" {
  _seed_legacy_pbi pbi-001 design
  jq '.bogus_key = "x"' .scrum/pbi/pbi-001/state.json > t.json && mv t.json .scrum/pbi/pbi-001/state.json
  # Scope is deliberately narrow: only `phase` is deleted. An unrelated
  # unknown key must still fail validation loudly rather than be silently
  # dropped by a blanket "remove unknown properties" pass.
  run MIGRATION
  [ "$status" -ne 0 ]
  run jq -e 'has("bogus_key")' .scrum/pbi/pbi-001/state.json
  [ "$status" -eq 0 ]
}

@test "004-drop-pbi-state-phase: rejects an unknown flag" {
  run MIGRATION --bogus
  [ "$status" -eq 64 ]
}
