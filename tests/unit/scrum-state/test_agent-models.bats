#!/usr/bin/env bats
# tests/unit/scrum-state/test_agent-models.bats — the per-seat LLM table
# wrapper (sole writer of .scrum/config.json.agents) and its frontmatter
# materialization.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/agent-models.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/agent-models.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state .claude/agents
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/config.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/model-catalog.json" docs/contracts/
  cp "$PROJECT_ROOT"/agents/*.md .claude/agents/
  SCRIPT="$PROJECT_ROOT/scripts/scrum/agent-models.sh"
  CATALOG="$PROJECT_ROOT/docs/contracts/model-catalog.json"
  INTEGRITY_FILES="requirement-conformance-reviewer functional-quality-reviewer security-reviewer maintainability-reviewer docs-consistency-reviewer"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

# First `<key>:` line inside the YAML frontmatter of an agent file.
fm_value() {
  awk -v key="$2" 'BEGIN{d=0} /^---$/{d++; if(d>1) exit; next} d==1 && index($0, key ":")==1 {sub("^" key ":[[:space:]]*", ""); print; exit}' "$1"
}

# --- set ---------------------------------------------------------------------

@test "agent-models set: creates config.json when absent" {
  [ ! -f .scrum/config.json ]
  run "$SCRIPT" set integrity-reviewers claude:sonnet@high
  [ "$status" -eq 0 ]
  [ -f .scrum/config.json ]
  [ "$(jq -c '.agents' .scrum/config.json)" = '{"integrity-reviewers":{"provider":"claude","model":"sonnet","effort":"high"}}' ]
  [[ "$output" == *"integrity-reviewers: claude sonnet (effort high)"* ]]
}

@test "agent-models set: upserts one seat, keeps other seats and unrelated keys" {
  cat > seed.json <<'EOF'
{"po_mode":"agent","merge_regression":{"command":"make test","accepted_none":false}}
EOF
  cp seed.json .scrum/config.json
  "$SCRIPT" set developer claude:sonnet@high
  run "$SCRIPT" set developer opus@medium
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents.developer.model' .scrum/config.json)" = "opus" ]
  [ "$(jq -r '.agents.developer.effort' .scrum/config.json)" = "medium" ]
  "$SCRIPT" set pbi-designer sonnet
  [ "$(jq -r '.agents | keys | join(",")' .scrum/config.json)" = "developer,pbi-designer" ]
  [ "$(jq -r '.po_mode' .scrum/config.json)" = "agent" ]
  [ "$(jq -r '.merge_regression.command' .scrum/config.json)" = "make test" ]
}

@test "agent-models set: result is validated against config.schema.json (E_SCHEMA=65, file untouched)" {
  printf '%s\n' '{"po_mode":"bogus"}' > seed.json
  cp seed.json .scrum/config.json
  run "$SCRIPT" set developer opus
  [ "$status" -eq 65 ]
  [[ "$output" == *"E_SCHEMA"* ]]
  cmp -s seed.json .scrum/config.json
}

@test "agent-models set: provider omitted resolves to the seat's default provider" {
  run "$SCRIPT" set scrum-master sonnet@low
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents["scrum-master"].provider' .scrum/config.json)" = "claude" ]
  run "$SCRIPT" set codex-reviewers gpt-5.6-luna
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents["codex-reviewers"].provider' .scrum/config.json)" = "codex" ]
  [ "$(jq -r '.agents["codex-reviewers"].model' .scrum/config.json)" = "gpt-5.6-luna" ]
}

@test "agent-models set: effort omitted keeps the previously configured effort" {
  "$SCRIPT" set developer opus@low
  run "$SCRIPT" set developer sonnet
  [ "$status" -eq 0 ]
  [ "$(jq -c '.agents.developer' .scrum/config.json)" = '{"provider":"claude","model":"sonnet","effort":"low"}' ]
}

@test "agent-models set: codex model 'default' is stored as null" {
  run "$SCRIPT" set codex-reviewers default
  [ "$status" -eq 0 ]
  [ "$(jq -c '.agents["codex-reviewers"]' .scrum/config.json)" = '{"provider":"codex","model":null}' ]
  [[ "$output" == *"codex-reviewers: codex default"* ]]
}

@test "agent-models set: model id outside the catalog menu is accepted with a WARN" {
  run "$SCRIPT" set developer claude:claude-brand-new-9
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"*"claude-brand-new-9"* ]]
  [ "$(jq -r '.agents.developer.model' .scrum/config.json)" = "claude-brand-new-9" ]
  # The WARN goes to stderr, not stdout.
  "$SCRIPT" set developer claude:claude-brand-new-9 2>/dev/null > out.txt
  ! grep -q WARN out.txt
}

# --- rejections ---------------------------------------------------------------

@test "agent-models set: rejections exit E_INVALID_ARG=64 and write nothing" {
  run "$SCRIPT" set nope opus
  [ "$status" -eq 64 ]; [[ "$output" == *"unknown seat"* ]]
  run "$SCRIPT" set developer codex:gpt-6-astra
  [ "$status" -eq 64 ]; [[ "$output" == *"provider codex not allowed"* ]]
  run "$SCRIPT" set codex-reviewers claude:opus
  [ "$status" -eq 64 ]; [[ "$output" == *"provider claude not allowed"* ]]
  run "$SCRIPT" set developer opus@ultra
  [ "$status" -eq 64 ]; [[ "$output" == *"unknown effort"* ]]
  run "$SCRIPT" set developer 'opus; rm -rf /'
  [ "$status" -eq 64 ]; [[ "$output" == *"unsafe model token"* ]]
  run "$SCRIPT" set developer '-opus'
  [ "$status" -eq 64 ]; [[ "$output" == *"unsafe model token"* ]]
  run "$SCRIPT" set codex-reviewers gpt-6-astra@high
  [ "$status" -eq 64 ]; [[ "$output" == *"no effort setting"* ]]
  run "$SCRIPT" set codex-reviewers 'a/b'
  [ "$status" -eq 64 ]; [[ "$output" == *"unsafe model token"* ]]
  run "$SCRIPT" set developer
  [ "$status" -eq 64 ]
  [ ! -f .scrum/config.json ]
}

@test "agent-models: --help exits 0; no/unknown subcommand exits 64" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: agent-models.sh"* ]]
  [[ "$output" == *"set-table"* ]]
  run "$SCRIPT"
  [ "$status" -eq 64 ]
  run "$SCRIPT" frobnicate
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

# --- set-table ------------------------------------------------------------------

@test "agent-models set-table: replaces the whole block in one write, codex null accepted" {
  "$SCRIPT" set pbi-designer sonnet@low
  run "$SCRIPT" set-table '{"codex-reviewers":{"provider":"codex","model":null},"developer":{"provider":"claude","model":"opus","effort":"high"}}'
  [ "$status" -eq 0 ]
  # Previous pbi-designer entry is gone; keys follow catalog order.
  [ "$(jq -r '.agents | keys_unsorted | join(",")' .scrum/config.json)" = "developer,codex-reviewers" ]
  [ "$(jq -c '.agents["codex-reviewers"]' .scrum/config.json)" = '{"provider":"codex","model":null}' ]
  # No leftover tmp files from the single atomic write.
  [ -z "$(ls .scrum | grep -v '^config.json$' | grep -v '^locks$' || true)" ]
}

@test "agent-models set-table: a seat missing from the catalog is dropped with a WARN, not rejected" {
  # A seat renamed/dropped by a later catalog must never wedge every write.
  run "$SCRIPT" set-table '{"ghost":{"provider":"claude","model":"opus"},"developer":{"provider":"claude","model":"haiku"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"*"dropping seat(s) not in the catalog: ghost"* ]]
  run jq -c '.agents | keys' .scrum/config.json
  [ "$output" = '["developer"]' ]
  run jq -r '.agents.developer.model' .scrum/config.json
  [ "$output" = "haiku" ]
}

@test "agent-models set-table: per-seat validation applies" {
  run "$SCRIPT" set-table '{"developer":{"provider":"codex","model":"x"}}'
  [ "$status" -eq 64 ]
  run "$SCRIPT" set-table '{"developer":{"provider":"claude","model":null}}'
  [ "$status" -eq 64 ]; [[ "$output" == *"null is only valid on a codex seat"* ]]
  run "$SCRIPT" set-table '{"codex-reviewers":{"provider":"codex","model":"gpt-6-astra","effort":"high"}}'
  [ "$status" -eq 64 ]
  run "$SCRIPT" set-table '{"developer":{"provider":"claude","model":"opus","extra":1}}'
  [ "$status" -eq 64 ]; [[ "$output" == *"unknown key"* ]]
  run "$SCRIPT" set-table 'not json'
  [ "$status" -eq 64 ]
  run "$SCRIPT" set-table '[]'
  [ "$status" -eq 64 ]
  [ ! -f .scrum/config.json ]
}

# --- resolve --------------------------------------------------------------------

@test "agent-models resolve: no config → catalog defaults, all 9 seats in catalog order" {
  run "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  expected_order="$(jq -r '.seats | to_entries | sort_by(.value.order) | map(.key) | join(",")' "$CATALOG")"
  [ "$(printf '%s' "$output" | jq -r 'keys_unsorted | join(",")')" = "$expected_order" ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 9 ]
  expected_defaults="$(jq -c '.seats | to_entries | sort_by(.value.order) | map({(.key): .value.default}) | add' "$CATALOG")"
  [ "$(printf '%s' "$output" | jq -c '.')" = "$expected_defaults" ]
}

@test "agent-models resolve: overlays .agents on the defaults (effort falls back to default)" {
  "$SCRIPT" set integrity-reviewers sonnet
  "$SCRIPT" set codex-reviewers gpt-5.6-sol
  run "$SCRIPT" resolve
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.["integrity-reviewers"]')" = '{"provider":"claude","model":"sonnet","effort":"xhigh"}' ]
  [ "$(printf '%s' "$output" | jq -c '.["codex-reviewers"]')" = '{"provider":"codex","model":"gpt-5.6-sol"}' ]
  [ "$(printf '%s' "$output" | jq -c '.developer')" = '{"provider":"claude","model":"sonnet","effort":"high"}' ]
  # Read-only: config untouched by resolve.
  before="$(cat .scrum/config.json)"
  "$SCRIPT" resolve >/dev/null
  [ "$(cat .scrum/config.json)" = "$before" ]
}

# --- materialize ------------------------------------------------------------------

@test "agent-models materialize: patches model+effort for claude seats, never inserts, leaves codex files" {
  "$SCRIPT" set integrity-reviewers sonnet@low
  "$SCRIPT" set codex-reviewers gpt-5.6-luna
  run "$SCRIPT" materialize
  [ "$status" -eq 0 ]
  for a in $INTEGRITY_FILES; do
    [ "$(fm_value ".claude/agents/$a.md" model)" = "sonnet" ]
    [ "$(fm_value ".claude/agents/$a.md" effort)" = "low" ]
    # Exactly one model:/effort: line in the frontmatter each — no insertion.
    [ "$(awk 'BEGIN{d=0} /^---$/{d++; if(d>1) exit; next} d==1 && /^model:/' ".claude/agents/$a.md" | wc -l | tr -d ' ')" -eq 1 ]
    # Body untouched: the section after the frontmatter is byte-identical.
    awk 'BEGIN{d=0} /^---$/{d++; next} d>=2' ".claude/agents/$a.md" > body.deployed
    awk 'BEGIN{d=0} /^---$/{d++; next} d>=2' "$PROJECT_ROOT/agents/$a.md" > body.source
    cmp -s body.deployed body.source
  done
  for a in scrum-explorer ceremony-operator; do
    ! grep -q '^model:' ".claude/agents/$a.md"
    ! grep -q '^effort:' ".claude/agents/$a.md"
    cmp -s ".claude/agents/$a.md" "$PROJECT_ROOT/agents/$a.md"
  done
  for a in codex-design-reviewer codex-impl-reviewer codex-ut-reviewer; do
    cmp -s ".claude/agents/$a.md" "$PROJECT_ROOT/agents/$a.md"
  done
  # Defaults were (re)applied to the other claude seats.
  [ "$(fm_value .claude/agents/developer.md model)" = "sonnet" ]
  [ "$(fm_value .claude/agents/scrum-master.md model)" = "opus" ]
  [[ "$output" == *"  integrity-reviewers: claude sonnet (effort low)"* ]]
  [[ "$output" == *"  codex-reviewers: codex gpt-5.6-luna (Codex CLI -m)"* ]]
  [[ "$output" == *"  scrum-master: claude opus (effort high)"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^  ')" -eq 9 ]
  [ -z "$(ls .claude/agents | grep tmp || true)" ]
}

@test "agent-models materialize: --agents-dir honoured, missing files skipped, codex default line" {
  mkdir -p alt
  cp "$PROJECT_ROOT/agents/security-reviewer.md" alt/
  "$SCRIPT" set integrity-reviewers opus@medium
  run "$SCRIPT" materialize --agents-dir alt
  [ "$status" -eq 0 ]
  [ "$(fm_value alt/security-reviewer.md effort)" = "medium" ]
  # Default dir untouched.
  [ "$(fm_value .claude/agents/security-reviewer.md effort)" = "xhigh" ]
  [[ "$output" == *"  codex-reviewers: codex default (Codex CLI -m)"* ]]
  run "$SCRIPT" materialize --bogus
  [ "$status" -eq 64 ]
}

# --- lib/frontmatter.sh helpers --------------------------------------------------

@test "frontmatter.sh: capture/patch touch only the first key inside the frontmatter" {
  cat > f.md <<'EOF'
---
name: x
model: "opus"
tools:
  - Read
effort: high
---
model: body-line-must-stay
effort: body
EOF
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/scripts/scrum/lib/frontmatter.sh"
  [ "$(capture_frontmatter_key f.md model)" = "opus" ]
  [ "$(capture_frontmatter_key f.md effort)" = "high" ]
  run capture_frontmatter_key f.md maxTurns
  [ "$status" -eq 1 ]; [ -z "$output" ]
  patch_frontmatter_key f.md model sonnet
  patch_frontmatter_key f.md effort low
  [ "$(fm_value f.md model)" = "sonnet" ]
  [ "$(fm_value f.md effort)" = "low" ]
  grep -q '^model: body-line-must-stay$' f.md
  grep -q '^effort: body$' f.md
  run patch_frontmatter_key f.md maxTurns 5
  [ "$status" -eq 1 ]
  ! grep -q maxTurns f.md
  run patch_frontmatter_key missing.md model x
  [ "$status" -eq 1 ]
  [ -z "$(ls | grep tmp || true)" ]
}
