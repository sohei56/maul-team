#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-006-add-audit-severity.bats —
# One-shot migration that back-fills `audit_severity` from the title's
# ":<Severity>]" suffix. The Medium→high row is the one that changes a
# runtime verdict (Integration-entry entry → block), so it is pinned here.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-asev.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-asev.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
  MIGRATION="$PROJECT_ROOT/scripts/scrum/migrations/006-add-audit-severity.sh"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Legacy backlog: severity lives only in the title suffix.
#   pbi-001..004 — the four legacy levels, all mappable
#   pbi-005      — audit PBI with no severity suffix, NOT mappable
#   pbi-006      — non-audit PBI, must never be touched
_seed_legacy_backlog() {
  cat > .scrum/backlog.json <<'EOF'
{
  "product_goal": "x",
  "next_pbi_id": 7,
  "items": [
    {
      "id": "pbi-001",
      "title": "[codebase-audit:sprint-001:F1:Critical] spec cannot be met",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-002",
      "title": "[codebase-audit:sprint-001:F2:High] latent bug",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-003",
      "title": "[codebase-audit:sprint-001:F3:Medium] retired level",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-004",
      "title": "[codebase-audit:sprint-001:F4:Low] cosmetic",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-005",
      "title": "[codebase-audit:sprint-001:F5] no suffix at all",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "id": "pbi-006",
      "title": "ordinary feature PBI",
      "status": "draft", "kind": "code",
      "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"
    }
  ]
}
EOF
}

sev() {
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .audit_severity // "absent"' .scrum/backlog.json
}

@test "006-add-audit-severity: maps the four legacy levels onto three" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [ "$(sev pbi-001)" = "critical" ]
  [ "$(sev pbi-002)" = "high" ]
  [ "$(sev pbi-003)" = "high" ]
  [ "$(sev pbi-004)" = "low" ]
}

@test "006-add-audit-severity: reports the medium→high count (the behavior change)" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rated 4"* ]]
  [[ "$output" == *"1 medium→high"* ]]
}

@test "006-add-audit-severity: leaves an unparseable suffix null and reports it" {
  _seed_legacy_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [ "$(sev pbi-005)" = "absent" ]
  [[ "$output" == *"1 still unkeyed"* ]]
}

@test "006-add-audit-severity: never touches non-audit PBIs" {
  _seed_legacy_backlog
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$(sev pbi-006)" = "absent" ]
}

@test "006-add-audit-severity: idempotent (second run is a no-op)" {
  _seed_legacy_backlog
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  HASH_BEFORE="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  # pbi-005 keeps no severity, so the candidate branch is re-entered; the write
  # is a semantic no-op because its suffix cannot be parsed.
  HASH_AFTER="$(jq -S '.items' .scrum/backlog.json | shasum | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "006-add-audit-severity: --dry-run reports the plan without writing" {
  _seed_legacy_backlog
  HASH_BEFORE="$(shasum .scrum/backlog.json | awk '{print $1}')"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would rate 4 of 5"* ]]
  [[ "$output" == *"1 medium→high"* ]]
  HASH_AFTER="$(shasum .scrum/backlog.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "006-add-audit-severity: clean no-op when backlog.json missing (migration contract)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "006-add-audit-severity: no-op when every audit PBI is already rated" {
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "006-add-audit-severity: usage error on unknown flag (exit 64)" {
  run "$MIGRATION" --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage:"* ]]
}
