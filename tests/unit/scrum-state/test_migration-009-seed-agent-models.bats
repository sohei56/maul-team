#!/usr/bin/env bats
# tests/unit/scrum-state/test_migration-009-seed-agent-models.bats —
# Legacy import for the per-seat LLM table `.scrum/config.json.agents`.
#
# Exercised in the DEPLOYED layout (.scrum/scripts/migrations/ + lib/, with
# target-local schemas) rather than from the source tree: the migration
# resolves the catalog beside the schema directory, and in the source layout
# that is always the framework's own copy — the "catalog not deployed" case
# would be untestable.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/migrate-agents.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/migrate-agents.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/scripts/lib .scrum/scripts/migrations docs/contracts/scrum-state
  cp "$PROJECT_ROOT/scripts/scrum/lib/"*.sh .scrum/scripts/lib/
  cp "$PROJECT_ROOT/scripts/scrum/migrations/009-seed-agent-models.sh" .scrum/scripts/migrations/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/config.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/model-catalog.json" docs/contracts/
  chmod +x .scrum/scripts/migrations/009-seed-agent-models.sh
  MIGRATION="$TEST_TMP/.scrum/scripts/migrations/009-seed-agent-models.sh"
  CONFIG="$TEST_TMP/.scrum/config.json"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# _deploy_agent <name> <model> [effort] — a deployed .claude/agents/<name>.md
# whose frontmatter carries the given model (and effort). The body carries a
# decoy `model:` line to pin the depth-bounded scan.
_deploy_agent() {
  mkdir -p .claude/agents
  {
    printf -- '---\nname: %s\ndescription: x\nmodel: %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf 'effort: %s\n' "$3"
    printf -- 'maxTurns: 10\n---\n\nBody.\n\nmodel: decoy-in-body\n'
  } > ".claude/agents/$1.md"
}

# Every catalog seat at its default, exactly as a launch with no prior
# selection would seed it.
_deploy_all_defaults() {
  local seat agent model effort
  for seat in $(jq -r '.seats | keys[]' docs/contracts/model-catalog.json); do
    agent="$(jq -r --arg s "$seat" '.seats[$s].agents[0]' docs/contracts/model-catalog.json)"
    model="$(jq -r --arg s "$seat" '.seats[$s].default.model // ""' docs/contracts/model-catalog.json)"
    effort="$(jq -r --arg s "$seat" '.seats[$s].default.effort // ""' docs/contracts/model-catalog.json)"
    [ -n "$model" ] || continue
    _deploy_agent "$agent" "$model" "$effort"
  done
}

_validate_config() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli bash -c '
    source "$1/scripts/scrum/lib/errors.sh"
    source "$1/scripts/scrum/lib/atomic.sh"
    _validate_against_schema "$2" "$1/docs/contracts/scrum-state/config.schema.json"
  ' _ "$PROJECT_ROOT" "$CONFIG"
}

@test "009: no config and no deployed agents is a skip that writes nothing" {
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  [ ! -f "$CONFIG" ]
  [ ! -d .scrum/locks ]
}

@test "009: an existing .agents block is a byte-identical no-op" {
  _deploy_agent scrum-master fable high
  printf '{"po_mode":"human","agents":{"scrum-master":{"provider":"claude","model":"haiku","effort":"low"}}}' > "$CONFIG"
  local before; before="$(cat "$CONFIG")"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$(cat "$CONFIG")" = "$before" ]
}

@test "009: imports SM and PO from deployed frontmatter, others stay at defaults, codex is null" {
  _deploy_all_defaults
  _deploy_agent scrum-master fable
  _deploy_agent product-owner haiku medium
  printf '{"po_mode":"human"}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"seeded agents (2 imported from deployed frontmatter)"* ]]
  run jq -c '.agents["scrum-master"]' "$CONFIG"
  [ "$output" = '{"provider":"claude","model":"fable","effort":"high"}' ]
  run jq -c '.agents["product-owner"]' "$CONFIG"
  [ "$output" = '{"provider":"claude","model":"haiku","effort":"medium"}' ]
  run jq -c '.agents["developer"]' "$CONFIG"
  [ "$output" = '{"provider":"claude","model":"sonnet","effort":"high"}' ]
  run jq -c '.agents["codex-reviewers"]' "$CONFIG"
  [ "$output" = '{"provider":"codex","model":null}' ]
  # every catalog seat is present, in catalog order; nothing else was touched
  run jq -r '.agents | keys_unsorted | join(",")' "$CONFIG"
  [ "$output" = "$(jq -r '.seats | to_entries | sort_by(.value.order) | map(.key) | join(",")' docs/contracts/model-catalog.json)" ]
  run jq -r '.po_mode' "$CONFIG"
  [ "$output" = "human" ]
}

@test "009: a quoted deployed model is imported unquoted (same YAML value)" {
  _deploy_agent scrum-master '"fable"'
  printf '{}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(1 imported from deployed frontmatter)"* ]]
  run jq -r '.agents["scrum-master"].model' "$CONFIG"
  [ "$output" = "fable" ]
}

@test "009: an invalid deployed model token falls back to the default with a WARNING" {
  _deploy_agent scrum-master 'bad token'
  printf '{}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"scrum-master"*"bad token"* ]]
  [[ "$output" == *"(0 imported from deployed frontmatter)"* ]]
  run jq -r '.agents["scrum-master"].model' "$CONFIG"
  [ "$output" = "opus" ]
}

@test "009: an effort outside the provider list falls back to the default with a WARNING" {
  _deploy_agent product-owner haiku ultra
  printf '{}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"product-owner"*"ultra"* ]]
  run jq -c '.agents["product-owner"]' "$CONFIG"
  [ "$output" = '{"provider":"claude","model":"haiku","effort":"xhigh"}' ]
}

@test "009: body text is never mistaken for frontmatter" {
  # Frontmatter with no model: line — only the body decoy carries one.
  mkdir -p .claude/agents
  printf -- '---\nname: scrum-master\n---\n\nmodel: decoy-in-body\n' > .claude/agents/scrum-master.md
  printf '{}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  run jq -r '.agents["scrum-master"].model' "$CONFIG"
  [ "$output" = "opus" ]
}

@test "009: no config but deployed agents creates config.json that validates" {
  _deploy_agent scrum-master fable
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [ -f "$CONFIG" ]
  run jq -r '.agents["scrum-master"].model' "$CONFIG"
  [ "$output" = "fable" ]
  run jq -r 'keys | join(",")' "$CONFIG"
  [ "$output" = "agents" ]
  run _validate_config
  [ "$status" -eq 0 ]
}

@test "009: the imported table validates against config.schema.json" {
  _deploy_all_defaults
  _deploy_agent product-owner claude-fable-5-1 xhigh
  printf '{"po_mode":"agent"}\n' > "$CONFIG"
  "$MIGRATION" >/dev/null 2>&1
  run _validate_config
  [ "$status" -eq 0 ]
}

@test "009: --dry-run reports the plan and writes nothing" {
  _deploy_agent scrum-master fable
  _deploy_agent product-owner haiku
  run "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would seed agents for 9 seats (2 imported from deployed frontmatter)"* ]]
  [ ! -f "$CONFIG" ]
  printf '{"po_mode":"human"}\n' > "$CONFIG"
  run "$MIGRATION" --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$CONFIG")" = '{"po_mode":"human"}' ]
}

@test "009: a second run is a byte-identical no-op" {
  _deploy_agent scrum-master fable
  printf '{"po_mode":"human"}\n' > "$CONFIG"
  "$MIGRATION" >/dev/null 2>&1
  local before; before="$(cat "$CONFIG")"
  # A later change to the deployed file must not be re-imported: the table
  # is the SSOT from the first seed on.
  _deploy_agent scrum-master haiku
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ "$(cat "$CONFIG")" = "$before" ]
}

@test "009: a missing catalog WARNs, exits 0, and writes nothing" {
  _deploy_agent scrum-master fable
  rm docs/contracts/model-catalog.json
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"model-catalog.json"* ]]
  [ ! -f "$CONFIG" ]
  printf '{"po_mode":"human"}\n' > "$CONFIG"
  run "$MIGRATION"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONFIG")" = '{"po_mode":"human"}' ]
}

@test "009: rejects an unknown flag" {
  run "$MIGRATION" --bogus
  [ "$status" -eq 64 ]
}
