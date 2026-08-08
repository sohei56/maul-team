#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-005-add-audit-identity.bats —
# One-shot migration that lifts the legacy `audit-id: <X>` marker out of the
# PBI description into the first-class `audit_identity` field.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-aid.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-aid.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Legacy backlog: the dedup key lives only inside `description`.
#   pbi-001 — already-normalized key, liftable
#   pbi-002 — path-shaped legacy key, NOT liftable (a machine cannot rename it)
#   pbi-003 — non-audit PBI, must never be touched
_seed_legacy_backlog() {
  cat > .scrum/backlog.json <<'EOF'
{
  "product_goal": "x",
  "next_pbi_id": 4,
  "items": [
    {
      "id": "pbi-001",
      "title": "[codebase-audit:sprint-001:F1:High] notify order inverted",
      "description": "Codebase-audit F1 (High). audit-id: notify-order::send-before-write. Occurrences: a.py:10 — run.",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-002",
      "title": "[codebase-audit:sprint-001:F2:Medium] participation window unit",
      "description": "audit-id: laneB/participation_job.py::is_open_for. Occurrences: b.py:20 — is_open_for.",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-02T10:00:00Z", "updated_at": "2026-03-02T10:00:00Z"
    },
    {
      "id": "pbi-003",
      "title": "ordinary feature PBI",
      "description": "no audit marker anywhere in here",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-03T10:00:00Z", "updated_at": "2026-03-03T10:00:00Z"
    }
  ]
}
EOF
}

@test "005-add-audit-identity: lifts a normalized marker into the field" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lifted 1"* ]]
  run jq -r '.items[] | select(.id == "pbi-001") | .audit_identity' .scrum/backlog.json
  [ "$output" = "notify-order::send-before-write" ]
}

@test "005-add-audit-identity: leaves a path-shaped legacy key unkeyed and reports it" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 audit PBIs still unkeyed"* ]]
  run jq -r '.items[] | select(.id == "pbi-002") | .audit_identity // "absent"' .scrum/backlog.json
  [ "$output" = "absent" ]
}

@test "005-add-audit-identity: never touches non-audit PBIs" {
  _seed_legacy_backlog
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  run jq -r '.items[] | select(.id == "pbi-003") | .audit_identity // "absent"' .scrum/backlog.json
  [ "$output" = "absent" ]
}

@test "005-add-audit-identity: idempotent (second run is no-op)" {
  _seed_legacy_backlog
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  HASH_BEFORE="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  [ "$status" -eq 0 ]
  # pbi-002 still carries a marker, so the candidate branch is re-entered; the
  # write is a semantic no-op because its key cannot be normalized.
  HASH_AFTER="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "005-add-audit-identity: --dry-run reports the plan without writing" {
  _seed_legacy_backlog
  HASH_BEFORE="$(shasum .scrum/backlog.json | awk '{print $1}')"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would lift 1 of 2"* ]]
  HASH_AFTER="$(shasum .scrum/backlog.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "005-add-audit-identity: clean no-op when backlog.json missing (migration contract)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "005-add-audit-identity: no-op when no audit PBI carries a marker" {
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "005-add-audit-identity: usage error on unknown flag (exit 64)" {
  run "$PROJECT_ROOT/scripts/scrum/migrations/005-add-audit-identity.sh" --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage:"* ]]
}
