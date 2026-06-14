#!/usr/bin/env bats
# tests/unit/scrum-state/test_migrate-add-kind-field.bats —
# One-shot migration that backfills kind="code" on existing PBIs.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-kind.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-kind.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Legacy backlog with NO kind field anywhere. Mimics pre-PR-1 data.
_seed_legacy_backlog() {
  cat > .scrum/backlog.json <<'EOF'
{
  "product_goal": "x",
  "next_pbi_id": 4,
  "items": [
    {
      "id": "pbi-001", "title": "first", "status": "done",
      "acceptance_criteria": ["ac1"], "design_doc_paths": [],
      "depends_on_pbi_ids": [], "ux_change": false, "priority": 1,
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-002", "title": "second", "status": "refined",
      "acceptance_criteria": ["ac1"], "design_doc_paths": [],
      "depends_on_pbi_ids": [], "ux_change": true, "priority": 2,
      "created_at": "2026-03-02T10:00:00Z", "updated_at": "2026-03-02T10:00:00Z"
    },
    {
      "id": "pbi-003", "title": "third", "status": "draft",
      "acceptance_criteria": [], "design_doc_paths": [],
      "depends_on_pbi_ids": [], "ux_change": false, "priority": 3,
      "created_at": "2026-03-03T10:00:00Z", "updated_at": "2026-03-03T10:00:00Z"
    }
  ]
}
EOF
}

@test "migrate-add-kind-field: backfills kind=code on every legacy item" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backfilled kind=\"code\" on 3 items"* ]]
  run jq -r '[.items[].kind] | unique[]' .scrum/backlog.json
  [ "$output" = "code" ]
}

@test "migrate-add-kind-field: idempotent (second run is no-op)" {
  _seed_legacy_backlog
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  HASH_BEFORE="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  HASH_AFTER="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "migrate-add-kind-field: preserves pre-existing kind=docs" {
  _seed_legacy_backlog
  # Promote pbi-002 to kind=docs (as if refinement had already tagged it
  # before the migration ran).
  jq '(.items[] | select(.id == "pbi-002")).kind = "docs"' .scrum/backlog.json > tmp.json
  mv tmp.json .scrum/backlog.json
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  run jq -r '.items[] | select(.id == "pbi-002") | .kind' .scrum/backlog.json
  [ "$output" = "docs" ]
  run jq -r '.items[] | select(.id == "pbi-001") | .kind' .scrum/backlog.json
  [ "$output" = "code" ]
  run jq -r '.items[] | select(.id == "pbi-003") | .kind' .scrum/backlog.json
  [ "$output" = "code" ]
}

@test "migrate-add-kind-field: refuses when backlog.json missing" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  [ "$status" -eq 67 ]
}

@test "migrate-add-kind-field: no-op on already-modern backlog (all kinds set)" {
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog-kind-docs.json" .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrate-add-kind-field.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}
