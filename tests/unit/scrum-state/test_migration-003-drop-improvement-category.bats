#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-003-drop-improvement-category.bats —
# One-shot migration that strips the deprecated `category` key from
# .scrum/improvements.json entries.
#
# Regression context: e1958ec removed `category` from the schema while entry
# items are additionalProperties:false, and .scrum/improvements.json sits in
# migrate-state.sh's BLOCKING STRICT_MAP. Without this migration a project
# whose improvements.json predates that commit hard-fails launch (exit 65)
# and the team never spawns.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-impcat.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-impcat.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/improvements.schema.json" docs/contracts/scrum-state/
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

MIGRATION() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/migrations/003-drop-improvement-category.sh" "$@"
}

# Validate through the SAME path production uses (lib/atomic.sh), rather than
# hardcoding one validator's CLI — the runner is resolved by
# lib/check-validator.sh and differs across machines.
VALIDATE() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli bash -c '
    source "$1/scripts/scrum/lib/errors.sh"
    source "$1/scripts/scrum/lib/atomic.sh"
    _validate_against_schema "$2" "$3"
  ' _ "$PROJECT_ROOT" "$1" "docs/contracts/scrum-state/improvements.schema.json"
}

# Pre-wrapper improvements.json: entries tagged with a free-form category.
_seed_legacy_improvements() {
  cat > .scrum/improvements.json <<'EOF'
{
  "entries": [
    {
      "id": "imp-0001", "sprint_id": "sprint-001",
      "description": "first", "status": "active",
      "created_at": "2026-03-01T10:00:00Z", "category": "process"
    },
    {
      "id": "imp-0002", "sprint_id": "sprint-001",
      "description": "second", "status": "archived",
      "created_at": "2026-03-02T10:00:00Z",
      "archived_at": "2026-03-09T10:00:00Z", "category": "tooling"
    },
    {
      "id": "imp-0003", "sprint_id": "sprint-002",
      "description": "third (already modern)", "status": "active",
      "created_at": "2026-03-03T10:00:00Z"
    }
  ],
  "last_consolidation_sprint": null
}
EOF
}

@test "003-drop-improvement-category: legacy file fails the schema before migrating (proves the launch-block)" {
  _seed_legacy_improvements
  # The seeded file must be REJECTED as-is — otherwise the migration is
  # unnecessary and the "result validates" test below proves nothing.
  run VALIDATE .scrum/improvements.json
  [ "$status" -ne 0 ]
}

@test "003-drop-improvement-category: strips category from every entry that carries it" {
  _seed_legacy_improvements
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"stripped category from 2 entries"* ]]
  run jq '[.entries[] | select(has("category"))] | length' .scrum/improvements.json
  [ "$output" = "0" ]
}

@test "003-drop-improvement-category: result validates against the current schema" {
  _seed_legacy_improvements
  MIGRATION
  run VALIDATE .scrum/improvements.json
  [ "$status" -eq 0 ]
}

@test "003-drop-improvement-category: preserves every other field" {
  _seed_legacy_improvements
  MIGRATION
  run jq -r '.entries[] | select(.id == "imp-0002") | "\(.sprint_id)|\(.description)|\(.status)|\(.archived_at)"' .scrum/improvements.json
  [ "$output" = "sprint-001|second|archived|2026-03-09T10:00:00Z" ]
  run jq -r '.entries | length' .scrum/improvements.json
  [ "$output" = "3" ]
}

@test "003-drop-improvement-category: idempotent (second run is no-op)" {
  _seed_legacy_improvements
  MIGRATION
  HASH_BEFORE="$(jq -S '.entries' .scrum/improvements.json | shasum | awk '{print $1}')"
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  HASH_AFTER="$(jq -S '.entries' .scrum/improvements.json | shasum | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "003-drop-improvement-category: --dry-run reports the plan without writing" {
  _seed_legacy_improvements
  HASH_BEFORE="$(shasum .scrum/improvements.json | awk '{print $1}')"
  run MIGRATION --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would strip category from 2 entries"* ]]
  HASH_AFTER="$(shasum .scrum/improvements.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "003-drop-improvement-category: clean no-op when improvements.json missing (migration contract)" {
  run MIGRATION
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "003-drop-improvement-category: rejects an unknown flag" {
  _seed_legacy_improvements
  run MIGRATION --bogus
  [ "$status" -eq 64 ]
}
