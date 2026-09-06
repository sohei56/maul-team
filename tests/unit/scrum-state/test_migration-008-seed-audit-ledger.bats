#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-008-seed-audit-ledger.bats —
# Paired migration for the new `.scrum/audit-ledger.json` SSOT file.
#
# It carries more weight than a back-fill: `add-backlog-item.sh` now requires
# an `--audit-identity` to name a class present in the ledger, but only WHEN
# THE LEDGER EXISTS. That bootstrap carve-out is safe only because this
# migration creates the file for every project that has a backlog. So "creates
# the file even with nothing to seed" is a correctness test, not a cosmetic one.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-ledger.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-ledger.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/audit-ledger.schema.json" \
     "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" \
     docs/contracts/scrum-state/
  MIGRATION="$PROJECT_ROOT/scripts/scrum/migrations/008-seed-audit-ledger.sh"
  WRAPPER="$PROJECT_ROOT/scripts/scrum/update-audit-ledger.sh"
  LEDGER="$TEST_TMP/.scrum/audit-ledger.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > runner0.sh
  chmod +x runner0.sh
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Legacy backlog: the class key lives on PBIs, nothing else exists.
#   class-a — one done + one cancelled          -> closed (evidence stamped)
#   class-b — one open                          -> open
#   class-c — cancelled only                    -> open (descoped ≠ fixed)
#   class-d — unparseable sprint in the title   -> skipped without sprint.json
#   pbi-006 — audit PBI with NO identity        -> ignored (nothing to key on)
#   pbi-007 — a normal PBI                      -> never touched
_seed_backlog() {
  cat > .scrum/backlog.json <<'EOF'
{
  "product_goal": "x",
  "next_pbi_id": 8,
  "items": [
    {"id":"pbi-001","title":"[codebase-audit:sprint-001:F1:Critical] a","status":"done","kind":"code",
     "audit_identity":"class-a::pattern-a","audit_severity":"critical",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-002","title":"[codebase-audit:sprint-003:F2:Low] a again","status":"cancelled","kind":"code",
     "audit_identity":"class-a::pattern-a","audit_severity":"low",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-003","title":"[codebase-audit:sprint-002:F3:High] b","status":"refined","kind":"code",
     "audit_identity":"class-b::pattern-b","audit_severity":"high",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-004","title":"[codebase-audit:sprint-002:F4:Low] c","status":"cancelled","kind":"code",
     "audit_identity":"class-c::pattern-c","audit_severity":"low",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-005","title":"[codebase-audit:bogus:F5:High] d","status":"draft","kind":"code",
     "audit_identity":"class-d::pattern-d","audit_severity":"high",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-006","title":"[codebase-audit:sprint-004:F6:High] unkeyed","status":"draft","kind":"code",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"},
    {"id":"pbi-007","title":"Normal PBI","status":"draft","kind":"code",
     "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"}
  ]
}
EOF
}

@test "008: no backlog is a clean no-op and writes nothing" {
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  [ ! -f "$LEDGER" ]
}

@test "008: creates the ledger even when there is nothing to seed" {
  # The bootstrap carve-out in add-backlog-item.sh depends on this: an
  # unmigrated target is allowed to file without a ledger, so every launched
  # project must actually get one.
  echo '{"product_goal":"x","next_pbi_id":1,"items":[]}' > .scrum/backlog.json
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [ -f "$LEDGER" ]
  run jq -r '.classes | length' "$LEDGER"
  [ "$output" = "0" ]
}

@test "008: --dry-run writes nothing" {
  _seed_backlog
  run "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -f "$LEDGER" ]
}

@test "008: seeds one class per distinct identity, with the documented status matrix" {
  _seed_backlog
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  run jq -r '.classes | length' "$LEDGER"
  [ "$output" = "3" ]
  # done + cancelled, nothing open -> closed, and the evidence names the source
  run jq -r '.classes[] | select(.identity=="class-a::pattern-a") | "\(.status)|\(.closed_evidence)"' "$LEDGER"
  [ "$output" = "closed|seeded by migration 008 from a done PBI" ]
  # an open PBI -> open
  run jq -r '.classes[] | select(.identity=="class-b::pattern-b") | .status' "$LEDGER"
  [ "$output" = "open" ]
  # cancelled-only -> open: descoped is not fixed, the class must stay detectable
  run jq -r '.classes[] | select(.identity=="class-c::pattern-c") | "\(.status)|\(.closed_evidence)"' "$LEDGER"
  [ "$output" = "open|null" ]
}

@test "008: severity is the highest across the class, sprints keep their exact ids" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  # class-a spans Critical (pbi-001) and Low (pbi-002): the class is as bad as
  # its worst sighting, mirroring the wrapper's monotonic raise.
  run jq -r '.classes[] | select(.identity=="class-a::pattern-a") | "\(.severity)|\(.first_seen_sprint)|\(.last_confirmed_sprint)"' "$LEDGER"
  [ "$output" = "critical|sprint-001|sprint-003" ]
}

@test "008: never invents occurrences, axis, or a detector" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  run jq -e 'all(.classes[]; (.occurrences == []) and (.axis == []) and (.detector == null))' "$LEDGER"
  [ "$status" -eq 0 ]
}

@test "008: links every matching PBI with role sweep, ignores unkeyed and non-audit items" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  run jq -c '.classes[] | select(.identity=="class-a::pattern-a") | .pbi_ids' "$LEDGER"
  [ "$output" = '[{"id":"pbi-001","role":"sweep"},{"id":"pbi-002","role":"sweep"}]' ]
  run jq -r '[.classes[].pbi_ids[].id] | index("pbi-006") // "absent"' "$LEDGER"
  [ "$output" = "absent" ]
  run jq -r '[.classes[].pbi_ids[].id] | index("pbi-007") // "absent"' "$LEDGER"
  [ "$output" = "absent" ]
}

@test "008: a class with no derivable sprint is skipped and reported, not invented" {
  _seed_backlog
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"class-d::pattern-d"* ]]
  run jq -r '[.classes[].identity] | index("class-d::pattern-d") // "absent"' "$LEDGER"
  [ "$output" = "absent" ]
}

@test "008: sprint.json supplies the fallback for an unparseable title" {
  _seed_backlog
  printf '{"id":"sprint-007","goal":"g","status":"active","developers":{}}\n' > .scrum/sprint.json
  "$MIGRATION" >/dev/null 2>&1
  run jq -r '.classes[] | select(.identity=="class-d::pattern-d") | "\(.first_seen_sprint)|\(.last_confirmed_sprint)"' "$LEDGER"
  [ "$output" = "sprint-007|sprint-007" ]
}

@test "008: a second run is a no-op" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  local before; before="$(cat "$LEDGER")"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$(cat "$LEDGER")" = "$before" ]
}

@test "008: a re-run preserves a hand-registered detector, occurrences, and status" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  echo '[{"path":"src/x.py","note":"found by hand"}]' > occ.json
  "$WRAPPER" add-occurrences --identity class-b::pattern-b --sprint sprint-005 --from occ.json >/dev/null
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$WRAPPER" register-detector \
    --identity class-b::pattern-b --command 'rg -q FORBIDDEN src/' --sprint sprint-005 >/dev/null
  "$WRAPPER" set-status --identity class-b::pattern-b --status sweeping >/dev/null
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  run jq -r '.classes[] | select(.identity=="class-b::pattern-b") | "\(.status)|\(.occurrences|length)|\(.detector.command)"' "$LEDGER"
  [ "$output" = "sweeping|1|rg -q FORBIDDEN src/" ]
}

@test "008: a newly-filed PBI for an existing class merges the link and nothing else" {
  _seed_backlog
  "$MIGRATION" >/dev/null 2>&1
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$WRAPPER" register-detector \
    --identity class-b::pattern-b --command 'true' --sprint sprint-005 >/dev/null
  jq '.items += [{"id":"pbi-008","title":"[codebase-audit:sprint-006:F7:Critical] b more","status":"draft","kind":"code","audit_identity":"class-b::pattern-b","audit_severity":"critical","created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"}]' \
    .scrum/backlog.json > b.tmp && mv b.tmp .scrum/backlog.json
  run "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 PBI link"* ]]
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  run jq -c '.classes[] | select(.identity=="class-b::pattern-b") | [.pbi_ids[].id]' "$LEDGER"
  [ "$output" = '["pbi-003","pbi-008"]' ]
  # severity stays where the wrapper left it: a re-run must not re-derive it
  run jq -r '.classes[] | select(.identity=="class-b::pattern-b") | "\(.severity)|\(.detector.command)"' "$LEDGER"
  [ "$output" = "high|true" ]
}

@test "008: rejects an unknown flag" {
  run "$MIGRATION" --bogus
  [ "$status" -eq 64 ]
}

@test "008: the result validates against audit-ledger.schema.json" {
  _seed_backlog
  printf '{"id":"sprint-007","goal":"g","status":"active","developers":{}}\n' > .scrum/sprint.json
  "$MIGRATION" >/dev/null 2>&1
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli bash -c '
    source "$1/scripts/scrum/lib/errors.sh"
    source "$1/scripts/scrum/lib/atomic.sh"
    _validate_against_schema "$2" "$1/docs/contracts/scrum-state/audit-ledger.schema.json"
  ' _ "$PROJECT_ROOT" "$LEDGER"
  [ "$status" -eq 0 ]
}
