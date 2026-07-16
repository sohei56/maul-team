#!/usr/bin/env bats
# tests/unit/scrum-state/test_migrate-state.bats —
# Launch-time upgrade gate: run every migration (lexical order, idempotent),
# then validate existing .scrum/*.json against the deployed schemas.
# Exercised in the DEPLOYED layout (.scrum/scripts/ + target-local schemas),
# exactly how scrum-start.sh invokes it.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-state.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-state.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  # Deployed layout: wrappers under .scrum/scripts/, schemas target-local.
  mkdir -p .scrum/scripts/lib .scrum/scripts/migrations docs/contracts/scrum-state
  cp "$PROJECT_ROOT/scripts/scrum/migrate-state.sh" .scrum/scripts/
  cp "$PROJECT_ROOT/scripts/scrum/lib/"*.sh .scrum/scripts/lib/
  cp "$PROJECT_ROOT/scripts/scrum/migrations/"*.sh .scrum/scripts/migrations/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/"*.schema.json docs/contracts/scrum-state/
  chmod +x .scrum/scripts/migrate-state.sh .scrum/scripts/migrations/*.sh
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

_seed_valid_state() {
  cp "$PROJECT_ROOT/tests/fixtures/valid-state.json" .scrum/state.json
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
  cp "$PROJECT_ROOT/tests/fixtures/valid-sprint.json" .scrum/sprint.json
}

# Backlog whose items lack `kind` — schema-valid (kind is optional) but
# pre-002 shape, so the 002 migration has real work to do.
_seed_kindless_backlog() {
  jq '.items |= map(del(.kind))' \
    "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" > .scrum/backlog.json
}

@test "migrate-state: no .scrum/ in cwd is a clean no-op" {
  mkdir empty && cd empty
  run bash "$TEST_TMP/.scrum/scripts/migrate-state.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}

@test "migrate-state: fresh project (no state files yet) passes" {
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok:"* ]]
}

@test "migrate-state: runs migrations then validates (pre-002 backlog gets kind backfilled)" {
  _seed_valid_state
  _seed_kindless_backlog
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"backfilled kind"* ]]
  [[ "$output" == *"ok:"* ]]
  run jq -r '[.items[].kind] | unique[]' .scrum/backlog.json
  [ "$output" = "code" ]
}

@test "migrate-state: idempotent (second run is a no-op and still exits 0)" {
  _seed_valid_state
  _seed_kindless_backlog
  bash .scrum/scripts/migrate-state.sh
  HASH_BEFORE="$(shasum .scrum/backlog.json | awk '{print $1}')"
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 0 ]
  HASH_AFTER="$(shasum .scrum/backlog.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "migrate-state: --dry-run forwards to migrations and writes nothing" {
  _seed_valid_state
  _seed_kindless_backlog
  HASH_BEFORE="$(shasum .scrum/backlog.json | awk '{print $1}')"
  run bash .scrum/scripts/migrate-state.sh --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would backfill"* ]]
  [[ "$output" == *"validation skipped"* ]]
  HASH_AFTER="$(shasum .scrum/backlog.json | awk '{print $1}')"
  [ "$HASH_BEFORE" = "$HASH_AFTER" ]
}

@test "migrate-state: strict state file violating its schema fails 65 and names the file" {
  _seed_valid_state
  cp "$PROJECT_ROOT/tests/fixtures/invalid-state-missing-phase.json" .scrum/state.json
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 65 ]
  [[ "$output" == *".scrum/state.json"* ]]
  [[ "$output" == *"violate the deployed schemas"* ]]
}

@test "migrate-state: every strict offender is listed, not just the first" {
  _seed_valid_state
  cp "$PROJECT_ROOT/tests/fixtures/invalid-state-missing-phase.json" .scrum/state.json
  echo '{"nonsense": true}' > .scrum/sprint.json
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 65 ]
  [[ "$output" == *".scrum/state.json"* ]]
  [[ "$output" == *".scrum/sprint.json"* ]]
  [[ "$output" == *"2 state file(s)"* ]]
}

@test "migrate-state: invalid pbi state.json is caught by the glob" {
  _seed_valid_state
  mkdir -p .scrum/pbi/pbi-001
  echo '{"bogus": 1}' > .scrum/pbi/pbi-001/state.json
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 65 ]
  [[ "$output" == *".scrum/pbi/pbi-001/state.json"* ]]
}

@test "migrate-state: hook-owned hot-path file only WARNs, launch not blocked" {
  _seed_valid_state
  echo '{"not_a_dashboard": true}' > .scrum/dashboard.json
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"*".scrum/dashboard.json"* ]]
  [[ "$output" == *"ok:"* ]]
}

@test "migrate-state: --check validates without running migrations" {
  _seed_valid_state
  _seed_kindless_backlog
  run bash .scrum/scripts/migrate-state.sh --check
  [ "$status" -eq 0 ]
  # kind still absent — migrations did not run.
  run jq '[.items[] | select(has("kind") | not)] | length' .scrum/backlog.json
  [ "$output" != "0" ]
}

@test "migrate-state: a failing migration aborts with its exit code" {
  _seed_valid_state
  printf '#!/usr/bin/env bash\nexit 66\n' > .scrum/scripts/migrations/999-boom.sh
  chmod +x .scrum/scripts/migrations/999-boom.sh
  run bash .scrum/scripts/migrate-state.sh
  [ "$status" -eq 66 ]
  [[ "$output" == *"migration FAILED: 999-boom.sh"* ]]
}

@test "migrate-state: rejects unknown flags with usage" {
  run bash .scrum/scripts/migrate-state.sh --wibble
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage:"* ]]
}
