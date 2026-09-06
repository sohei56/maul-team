#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-007-po-decisions-evidence-nonempty.bats —
# Paired data migration for the `evidence` items tightening
# (`"pattern": "\\S"`) in po-decisions.schema.json. A blank entry left behind
# does not merely fail the launch gate: append-po-decision.sh writes through
# atomic_write, which re-validates the WHOLE file, so it bricks every future
# append.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-poev.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-poev.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/po docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/po-decisions.schema.json" docs/contracts/scrum-state/
  MIGRATION="$PROJECT_ROOT/scripts/scrum/migrations/007-po-decisions-evidence-nonempty.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Legacy store written before the wrapper rejected a blank --evidence.
#   dec-0001 — mixed: two blanks around one real path (cleanable)
#   dec-0002 — no evidence key at all (must stay untouched)
#   dec-0003 — non-approval kind, only blanks (cleanable → [])
#   dec-0004 — clean already (must stay byte-identical)
_seed_store() {
  cat > .scrum/po/decisions.json <<'EOF'
{
  "decisions": [
    {
      "id": "dec-0001",
      "timestamp": "2026-08-01T10:00:00Z",
      "sprint_id": "sprint-001",
      "pbi_id": "pbi-001",
      "kind": "demo_acceptance",
      "decision": "pass",
      "rationale": "demo ran",
      "evidence": ["", ".scrum/pbi/pbi-001/demo.log", "   "],
      "assumption": false
    },
    {
      "id": "dec-0002",
      "timestamp": "2026-08-01T11:00:00Z",
      "kind": "sprint_goal_approval",
      "decision": "approve",
      "rationale": "goal is clear",
      "assumption": false
    },
    {
      "id": "dec-0003",
      "timestamp": "2026-08-01T12:00:00Z",
      "kind": "spec_clarification",
      "decision": "use option B",
      "rationale": "cheaper",
      "evidence": ["", "\t"],
      "assumption": false
    },
    {
      "id": "dec-0004",
      "timestamp": "2026-08-01T13:00:00Z",
      "kind": "release_decision",
      "decision": "no_go",
      "rationale": "tests red",
      "evidence": [".scrum/test-results.json"],
      "assumption": false
    }
  ]
}
EOF
}

# An approval-kind record whose ONLY evidence entry is blank. Guard (b) in
# append-po-decision.sh wants at least one path, but the schema carries no
# minItems, so the record is still cleaned — and warned about by id.
_seed_store_with_empty_approval() {
  _seed_store
  jq '.decisions += [{
    "id": "dec-0005",
    "timestamp": "2026-08-01T14:00:00Z",
    "sprint_id": "sprint-001",
    "kind": "sprint_acceptance",
    "decision": "approve",
    "rationale": "looked fine",
    "evidence": ["  "],
    "assumption": false
  }]' .scrum/po/decisions.json > tmp.json && mv tmp.json .scrum/po/decisions.json
}

ev() {
  jq -c --arg id "$1" '.decisions[] | select(.id == $id) | .evidence // "absent"' \
    .scrum/po/decisions.json
}

hash_store() {
  shasum .scrum/po/decisions.json | awk '{print $1}'
}

@test "007-po-decisions-evidence-nonempty: drops blank entries, keeps order" {
  _seed_store
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [ "$(ev dec-0001)" = '[".scrum/pbi/pbi-001/demo.log"]' ]
  [ "$(ev dec-0003)" = '[]' ]
  [ "$(ev dec-0002)" = '"absent"' ]
  [ "$(ev dec-0004)" = '[".scrum/test-results.json"]' ]
  [[ "$output" == *"dropped 4 blank evidence entries across 2 decisions"* ]]
}

@test "007-po-decisions-evidence-nonempty: preserves every other field" {
  _seed_store
  BEFORE="$(jq -S 'del(.decisions[].evidence)' .scrum/po/decisions.json)"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  AFTER="$(jq -S 'del(.decisions[].evidence)' .scrum/po/decisions.json)"
  [ "$BEFORE" = "$AFTER" ]
}

@test "007-po-decisions-evidence-nonempty: result satisfies the tightened schema" {
  _seed_store
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  run jsonschema --instance .scrum/po/decisions.json \
    docs/contracts/scrum-state/po-decisions.schema.json
  [ "$status" -eq 0 ]
}

@test "007-po-decisions-evidence-nonempty: idempotent (second run is a no-op)" {
  _seed_store
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  HASH_BEFORE="$(hash_store)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$HASH_BEFORE" = "$(hash_store)" ]
}

@test "007-po-decisions-evidence-nonempty: clean no-op when decisions.json missing" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  [ ! -f .scrum/po/decisions.json ]
}

@test "007-po-decisions-evidence-nonempty: no-op on an empty decisions array" {
  echo '{"decisions": []}' > .scrum/po/decisions.json
  HASH_BEFORE="$(hash_store)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$HASH_BEFORE" = "$(hash_store)" ]
}

@test "007-po-decisions-evidence-nonempty: cleans an approval whose only evidence is blank, and warns" {
  _seed_store_with_empty_approval
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  # The record is kept and cleaned — the schema has no minItems, so [] is
  # valid and the launch gate passes.
  [ "$(ev dec-0005)" = '[]' ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"dec-0005 (kind=sprint_acceptance)"* ]]
  [[ "$output" == *"attach evidence"* ]]
  [[ "$output" == *"dropped 5 blank evidence entries across 3 decisions"* ]]
  [[ "$output" == *"1 approval records left with no evidence"* ]]
}

@test "007-po-decisions-evidence-nonempty: emptied approval leaves a schema-valid file" {
  _seed_store_with_empty_approval
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  run jsonschema --instance .scrum/po/decisions.json \
    docs/contracts/scrum-state/po-decisions.schema.json
  [ "$status" -eq 0 ]
}

@test "007-po-decisions-evidence-nonempty: holds the file on a non-string entry" {
  cat > .scrum/po/decisions.json <<'EOF'
{
  "decisions": [
    {
      "id": "dec-0001",
      "timestamp": "2026-08-01T10:00:00Z",
      "kind": "spec_clarification",
      "decision": "x",
      "rationale": "y",
      "evidence": ["", 42]
    }
  ]
}
EOF
  HASH_BEFORE="$(hash_store)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  # 42 predates this tightening and cannot be interpreted, so the file is left
  # byte-identical. Still exit 0 — a migration must not abort the launch.
  [ "$status" -eq 0 ]
  [[ "$output" == *"non-string evidence entry"* ]]
  [[ "$output" == *"dec-0001"* ]]
  [[ "$output" == *"held"* ]]
  [ "$HASH_BEFORE" = "$(hash_store)" ]
}

@test "007-po-decisions-evidence-nonempty: --dry-run reports the plan without writing" {
  _seed_store
  HASH_BEFORE="$(hash_store)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would drop 4 blank evidence entries across 2 decisions"* ]]
  [[ "$output" == *"0 approval records would be left with no evidence"* ]]
  [ "$HASH_BEFORE" = "$(hash_store)" ]
}

@test "007-po-decisions-evidence-nonempty: idempotent after emptying an approval" {
  _seed_store_with_empty_approval
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  HASH_BEFORE="$(hash_store)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$HASH_BEFORE" = "$(hash_store)" ]
}

@test "007-po-decisions-evidence-nonempty: usage error on unknown flag (exit 64)" {
  run "$MIGRATION" --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage:"* ]]
}
