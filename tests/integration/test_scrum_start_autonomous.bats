#!/usr/bin/env bats
# tests/integration/test_scrum_start_autonomous.bats
#
# Verifies the autonomous-PO startup path inside scrum-start.sh:
#   - --autonomous --brief on a new project copies brief, merges config,
#     initialises autonomy.json.
#   - --autonomous on a new project WITHOUT --brief is rejected (exit 2).
#   - --max-sprints CLI override propagates into .scrum/config.json.
#   - A plain `scrum-start.sh` (no flags) does NOT inject po_mode or the
#     autonomous block (regression).
#   - Per-seat model table (.scrum/config.json.agents): --sm-model /
#     --po-model / --agent-model persistence + materialized frontmatter,
#     legacy frontmatter import (migration 009), and pre-side-effect
#     rejections (exit 2, nothing deployed).
#
# Uses SCRUM_START_DRY_RUN=1 to short-circuit just before the actual
# tmux / claude / watchdog launch, and a PATH shim that provides stub `claude`
# and `python3` so the prereq checks in scrum-start.sh succeed without
# touching the user's real environment.

load '../test_helper/common-setup'

setup() {
  setup_temp_dir
  export PROJECT_ROOT

  # Build a PATH shim with stub `claude` and `python3` that satisfy
  # check-python.sh. The real `jq`, `cp`, `mkdir`, etc. are inherited via
  # PATH passthrough.
  STUB_BIN="$TEMP_DIR/stub-bin"
  mkdir -p "$STUB_BIN"

  cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --version|-V) echo "stub-claude 0.0.1"; exit 0 ;; esac
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # Wrap real python3 so the version + module checks pass without
  # auto-installing anything.
  REAL_PY="$(command -v python3 || true)"
  cat > "$STUB_BIN/python3" <<EOF
#!/usr/bin/env bash
exec "$REAL_PY" "\$@"
EOF
  chmod +x "$STUB_BIN/python3"

  # Pre-populate Python modules check by setting env to skip pip install if
  # they happen to be missing. check_python_prereqs auto-installs, but on
  # CI hosts where pip is locked, we still want the test to proceed. We
  # tolerate either branch — the test asserts only on autonomous-prep
  # behaviour, not on prereq output.
  export PATH="$STUB_BIN:$PATH"

  # Source brief used by tests that pass --brief.
  mkdir -p "$TEMP_DIR/seed"
  cat > "$TEMP_DIR/seed/brief.md" <<'EOF'
# Test product brief
Goal: ship a thing.
EOF

  # Empty target dir for the project.
  PROJ_DIR="$TEMP_DIR/proj"
  mkdir -p "$PROJ_DIR"
  cd "$PROJ_DIR" || exit 1

  export SCRUM_START_DRY_RUN=1

  # init-state.sh runs in the new-project branch and validates against the
  # state schema. Pin the validator to a locally-installed runner so the
  # test does not depend on npx fetching ajv-cli from npm.
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
}

teardown() {
  teardown_temp_dir
}

# --- (a) --autonomous --brief on a new project ------------------------------

@test "scrum-start --autonomous --brief: copies brief, merges config, inits autonomy.json" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous \
    --brief "$TEMP_DIR/seed/brief.md"

  [ "$status" -eq 0 ]

  # brief.md placed in canonical location
  [ -f "docs/product/brief.md" ]
  grep -q 'Test product brief' docs/product/brief.md

  # config.json has po_mode=agent + autonomous defaults
  [ -f ".scrum/config.json" ]
  run jq -r '.po_mode' .scrum/config.json
  [ "$output" = "agent" ]
  run jq -r '.autonomous.max_iterations' .scrum/config.json
  [ "$output" = "50" ]
  run jq -r '.autonomous.permission_mode' .scrum/config.json
  [ "$output" = "dontAsk" ]

  # autonomy.json initialised
  [ -f ".scrum/autonomy.json" ]
  run jq -r '.iteration' .scrum/autonomy.json
  [ "$output" = "0" ]
  run jq -r '.run_id' .scrum/autonomy.json
  [ -n "$output" ]
  [ "$output" != "null" ]

  # state.json bootstrapped via init-state.sh (new-project branch)
  [ -f ".scrum/state.json" ]
  run jq -r '.phase' .scrum/state.json
  [ "$output" = "new" ]
}

# --- (a2) Plain --no-autonomous new-project run bootstraps state.json --------

@test "scrum-start (no flags) on new project bootstraps .scrum/state.json" {
  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  [ -f ".scrum/state.json" ]
  run jq -r '.phase' .scrum/state.json
  [ "$output" = "new" ]
  run jq -r '.current_sprint_id' .scrum/state.json
  [ "$output" = "null" ]
}

# --- (b) --autonomous without brief on a new project → exit 2 ---------------

@test "scrum-start --autonomous on new project requires --brief (exits 2)" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --brief"* ]]
}

# Non-TTY (the bats run is never a TTY) cannot co-author a brief, so the
# error must mention the interactive create-brief escape hatch.
@test "scrum-start --autonomous no-brief error points to the create-brief skill" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous
  [ "$status" -eq 2 ]
  [[ "$output" == *"create-brief"* ]]
}

# An explicit --brief that names a missing (non-canonical) path is a typo,
# not a request to co-author — fail loudly.
@test "scrum-start --autonomous --brief <missing path> exits 2 (typo, not builder)" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous --brief "$TEMP_DIR/seed/does-not-exist.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"brief file not found"* ]]
}

# A canonical brief already in place is never clobbered, even when --brief
# names a different existing file.
@test "scrum-start --autonomous keeps an existing canonical brief" {
  mkdir -p docs/product
  printf '# Existing canonical brief\nkeep me.\n' > docs/product/brief.md

  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous --brief "$TEMP_DIR/seed/brief.md"
  [ "$status" -eq 0 ]

  # The pre-existing file wins; the seed brief is NOT copied over it.
  grep -q 'Existing canonical brief' docs/product/brief.md
  ! grep -q 'Test product brief' docs/product/brief.md
}

# --- (c) Non-autonomous launch does NOT inject po_mode / autonomous ---------

@test "scrum-start (no flags) leaves config.json untouched (regression)" {
  # Seed a state.json so the script takes the "existing project" branch
  # (skips prompting for new project) and then enters the dry-run launch.
  mkdir -p .scrum
  cat > .scrum/state.json <<'JSON'
{
  "phase": "requirements_sprint",
  "current_sprint_id": null,
  "product_goal": "x",
  "created_at": "2026-06-12T00:00:00Z",
  "updated_at": "2026-06-12T00:00:00Z"
}
JSON

  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]

  # No autonomous side effects.
  [ ! -f ".scrum/config.json" ] || {
    run jq -r '.po_mode // "absent"' .scrum/config.json
    [ "$output" = "absent" ]
    run jq -r '.autonomous // "absent"' .scrum/config.json
    [ "$output" = "absent" ]
  }
  [ ! -f ".scrum/autonomy.json" ]

  # The per-seat model table IS written on every launch (catalog defaults,
  # 9 seats) — it is the SSOT for model selection, not an autonomous artefact.
  [ -f ".scrum/config.json" ]
  run jq -r '.agents | type' .scrum/config.json
  [ "$output" = "object" ]
  run jq -r '.agents | keys | length' .scrum/config.json
  [ "$output" = "9" ]
  run jq -r '.agents."scrum-master".model' .scrum/config.json
  [ "$output" = "opus" ]
}

@test "scrum-start (no flags) resets leftover po_mode=agent to human" {
  # A prior --autonomous run left po_mode=agent + an autonomous tuning block
  # in config.json. A plain start must flip po_mode back to human (so the SM
  # does not re-spawn the PO teammate) while preserving .autonomous.*.
  mkdir -p .scrum
  cat > .scrum/state.json <<'JSON'
{
  "phase": "requirements_sprint",
  "current_sprint_id": null,
  "product_goal": "x",
  "created_at": "2026-06-12T00:00:00Z",
  "updated_at": "2026-06-12T00:00:00Z"
}
JSON
  cat > .scrum/config.json <<'JSON'
{
  "po_mode": "agent",
  "autonomous": {"max_sprints": 8, "max_iterations": 50}
}
JSON

  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]

  # po_mode reset to human ...
  run jq -r '.po_mode' .scrum/config.json
  [ "$output" = "human" ]
  # ... but the autonomous tuning block is preserved untouched.
  run jq -r '.autonomous.max_sprints' .scrum/config.json
  [ "$output" = "8" ]
  run jq -r '.autonomous.max_iterations' .scrum/config.json
  [ "$output" = "50" ]
}

# --- (d) --max-sprints override is reflected in config.json -----------------

@test "scrum-start --autonomous --max-sprints N overrides config" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous \
    --brief "$TEMP_DIR/seed/brief.md" \
    --max-sprints 12 \
    --max-hours 4 \
    --bypass-permissions

  [ "$status" -eq 0 ]
  run jq -r '.autonomous.max_sprints' .scrum/config.json
  [ "$output" = "12" ]
  run jq -r '.autonomous.max_wall_clock_hours' .scrum/config.json
  [ "$output" = "4" ]
  run jq -r '.autonomous.permission_mode' .scrum/config.json
  [ "$output" = "bypassPermissions" ]
}

# --- (e) PO model: default opus applied to deployed agent file --------------
# SSOT is `.scrum/config.json.agents."product-owner"` (per-seat model table);
# the deployed .claude/agents/product-owner.md `model:` line is materialized
# from it. The legacy `.autonomous.po_model` shadow key must never appear.

@test "scrum-start --autonomous (no --po-model): deployed PO agent file defaults to opus" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous \
    --brief "$TEMP_DIR/seed/brief.md"

  [ "$status" -eq 0 ]

  # No legacy shadow key; the seat table carries the catalog default.
  run jq -r '.autonomous | has("po_model")' .scrum/config.json
  [ "$output" = "false" ]
  run jq -r '.agents."product-owner".model' .scrum/config.json
  [ "$output" = "opus" ]

  # Deployed agent file's frontmatter `model:` line was materialized.
  [ -f ".claude/agents/product-owner.md" ]
  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: opus" ]
}

# --- (f) --po-model lands in the seat table and the deployed agent file -----

@test "scrum-start --autonomous --po-model sonnet patches deployed agent file" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous \
    --brief "$TEMP_DIR/seed/brief.md" \
    --po-model sonnet

  [ "$status" -eq 0 ]

  # Seat table is the SSOT; no legacy shadow key.
  run jq -r '.autonomous | has("po_model")' .scrum/config.json
  [ "$output" = "false" ]
  run jq -r '.agents."product-owner".model' .scrum/config.json
  [ "$output" = "sonnet" ]

  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: sonnet" ]
}

# --- (g) --po-model is accepted in human-PO mode and persisted --------------

@test "scrum-start --po-model without --autonomous persists the PO seat" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --po-model haiku
  [ "$status" -eq 0 ]
  [[ "$output" == *"Product Owner model persisted"* ]]

  run jq -r '.agents."product-owner".model' .scrum/config.json
  [ "$output" = "haiku" ]
  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: haiku" ]
}

# --- (h) --po-model choice persists across re-runs via the seat table -------
# A prior --po-model choice survives a re-run with no flag because
# `.scrum/config.json.agents` is the memory; setup-user.sh restores the
# source default in the agent file and materialize re-applies the table.

@test "scrum-start --autonomous: --po-model sonnet persists to next run" {
  # Run 1 — set sonnet, creates .scrum/state.json so Run 2 takes the
  # resume branch (no --brief required).
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous \
    --brief "$TEMP_DIR/seed/brief.md" \
    --po-model sonnet
  [ "$status" -eq 0 ]
  run jq -r '.agents."product-owner".model' .scrum/config.json
  [ "$output" = "sonnet" ]
  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: sonnet" ]

  # Run 2 — no --po-model. The persisted seat table wins over the source
  # default that setup-user.sh just re-deployed.
  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous
  [ "$status" -eq 0 ]
  run jq -r '.agents."product-owner".model' .scrum/config.json
  [ "$output" = "sonnet" ]
  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: sonnet" ]

  # And still no legacy shadow key in config.
  run jq -r '.autonomous | has("po_model")' .scrum/config.json
  [ "$output" = "false" ]
}

# --- (i) Scrum Master model is independent of PO mode and PO model ----------

@test "scrum-start defaults deployed Scrum Master model to opus in human PO mode" {
  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$status" -eq 0 ]
  [ "$output" = "model: opus" ]
}

@test "scrum-start --sm-model accepts explicit alias in human PO mode" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --sm-model sonnet
  [ "$status" -eq 0 ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$output" = "model: sonnet" ]
}

@test "scrum-start --autonomous --sm-model accepts custom model ID" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous --brief "$TEMP_DIR/seed/brief.md" \
    --sm-model claude-opus-4-1-20250805
  [ "$status" -eq 0 ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$output" = "model: claude-opus-4-1-20250805" ]
}

@test "scrum-start keeps Scrum Master and Product Owner model choices independent" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --autonomous --brief "$TEMP_DIR/seed/brief.md" \
    --sm-model fable --po-model haiku
  [ "$status" -eq 0 ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$output" = "model: fable" ]
  run grep -E '^model:' .claude/agents/product-owner.md
  [ "$output" = "model: haiku" ]
}

@test "scrum-start persists Scrum Master model across setup refreshes" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --sm-model haiku
  [ "$status" -eq 0 ]
  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$output" = "model: haiku" ]
}

@test "scrum-start rejects unsafe Scrum Master model syntax" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --sm-model 'opus: unsafe'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--sm-model must be"* ]]

  run bash "$PROJECT_ROOT/scrum-start.sh" --sm-model ''
  [ "$status" -eq 2 ]
  [[ "$output" == *"--sm-model must be"* ]]
}

@test "scrum-start rejects empty, multiline, and colon Product Owner models" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous --po-model ''
  [ "$status" -eq 2 ]
  [[ "$output" == *"--po-model must be"* ]]

  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous --po-model 'opus:unsafe'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--po-model must be"* ]]

  run bash "$PROJECT_ROOT/scrum-start.sh" --autonomous --po-model $'opus\nhaiku'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--po-model must be"* ]]
}

@test "scrum-start rejects multiline Scrum Master model syntax" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --sm-model $'opus\nhaiku'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--sm-model must be"* ]]
}

@test "scrum-start help documents Scrum Master model flag" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--agent-model <seat>"* ]]
  [[ "$output" == *"--sm-model <name>"* ]]
  [[ "$output" == *"human-PO and"* ]]
}

# --- (j) Per-seat model table: legacy import, --agent-model, rejections -----

# A project launched before the table existed carries its last model choice
# only in deployed frontmatter. Migration 009 (run from source BEFORE
# setup-user.sh overwrites the file) imports it into .agents.
@test "scrum-start imports a legacy deployed frontmatter model into .agents" {
  mkdir -p .claude/agents
  printf -- '---\nname: scrum-master\nmodel: fable\neffort: high\n---\nbody\n' \
    > .claude/agents/scrum-master.md
  [ ! -f ".scrum/config.json" ]

  run bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"seeded agents"* ]]

  run jq -r '.agents."scrum-master".model' .scrum/config.json
  [ "$output" = "fable" ]
  run grep -E '^model:' .claude/agents/scrum-master.md
  [ "$output" = "model: fable" ]
}

@test "scrum-start --agent-model integrity-reviewers fans out to all five reviewer files" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --agent-model integrity-reviewers=claude:sonnet@high
  [ "$status" -eq 0 ]

  local f
  for f in requirement-conformance-reviewer functional-quality-reviewer \
           security-reviewer maintainability-reviewer docs-consistency-reviewer; do
    run grep -E '^model:' ".claude/agents/$f.md"
    [ "$output" = "model: sonnet" ]
    run grep -E '^effort:' ".claude/agents/$f.md"
    [ "$output" = "effort: high" ]
  done

  # Excluded agents carry no model: line at all.
  [ -f ".claude/agents/scrum-explorer.md" ]
  [ -f ".claude/agents/ceremony-operator.md" ]
  ! grep -qE '^model:' .claude/agents/scrum-explorer.md
  ! grep -qE '^model:' .claude/agents/ceremony-operator.md

  run jq -c '.agents."integrity-reviewers"' .scrum/config.json
  [ "$output" = '{"provider":"claude","model":"sonnet","effort":"high"}' ]
}

@test "scrum-start --agent-model codex-reviewers persists a codex model without touching frontmatter" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --agent-model codex-reviewers=codex:gpt-5.6-luna
  [ "$status" -eq 0 ]
  run jq -r '.agents."codex-reviewers".model' .scrum/config.json
  [ "$output" = "gpt-5.6-luna" ]
  run jq -r '.agents."codex-reviewers".provider' .scrum/config.json
  [ "$output" = "codex" ]
  # Codex seats are not materialized: the deployed file keeps its source default.
  run grep -E '^model:' .claude/agents/codex-impl-reviewer.md
  [ "$output" = "model: sonnet" ]

  # `codex:default` = Codex CLI default (no -m) → stored as null.
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --agent-model codex-reviewers=codex:default
  [ "$status" -eq 0 ]
  run jq -r '.agents."codex-reviewers" | has("model") and (.model == null)' .scrum/config.json
  [ "$output" = "true" ]
}

@test "scrum-start --agent-model with provider omitted uses the seat default provider and effort" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer=opus
  [ "$status" -eq 0 ]
  run jq -c '.agents.developer' .scrum/config.json
  [ "$output" = '{"provider":"claude","model":"opus","effort":"high"}' ]
  run grep -E '^model:' .claude/agents/developer.md
  [ "$output" = "model: opus" ]
}

@test "scrum-start --agent-model keeps a persisted effort when a later override omits it" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer=claude:opus@xhigh
  [ "$status" -eq 0 ]
  run jq -r '.agents.developer.effort' .scrum/config.json
  [ "$output" = "xhigh" ]

  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer=sonnet
  [ "$status" -eq 0 ]
  run jq -r '.agents.developer.model' .scrum/config.json
  [ "$output" = "sonnet" ]
  run jq -r '.agents.developer.effort' .scrum/config.json
  [ "$output" = "xhigh" ]
  run grep -E '^effort:' .claude/agents/developer.md
  [ "$output" = "effort: xhigh" ]
}

# Each rejection exits 2 BEFORE any side effect: nothing is deployed.
@test "scrum-start --agent-model rejects an unknown seat" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model nope=opus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown seat"* ]]
  [ ! -d ".claude/agents" ]
}

@test "scrum-start --agent-model rejects a provider the seat does not allow" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer=codex:gpt-6-astra
  [ "$status" -eq 2 ]
  [[ "$output" == *"not allowed"* ]]
  [ ! -d ".claude/agents" ]

  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model codex-reviewers=claude:opus
  [ "$status" -eq 2 ]
  [[ "$output" == *"not allowed"* ]]
  [ ! -d ".claude/agents" ]
}

@test "scrum-start rejects the same seat set more than once" {
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --agent-model developer=opus --agent-model developer=sonnet
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
  [ ! -d ".claude/agents" ]

  # --sm-model overlapping with --agent-model scrum-master=...
  run bash "$PROJECT_ROOT/scrum-start.sh" \
    --sm-model opus --agent-model scrum-master=sonnet
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
  [ ! -d ".claude/agents" ]
}

@test "scrum-start --agent-model rejects a bad effort, an unsafe token, and a missing '='" {
  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer=opus@turbo
  [ "$status" -eq 2 ]
  [[ "$output" == *"effort"* ]]
  [ ! -d ".claude/agents" ]

  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer='op us'
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be"* ]]
  [ ! -d ".claude/agents" ]

  run bash "$PROJECT_ROOT/scrum-start.sh" --agent-model developer
  [ "$status" -eq 2 ]
  [[ "$output" == *"expects"* ]]
  [ ! -d ".claude/agents" ]
}

@test "resume startup prompt uses SessionStart summary and targeted explorer" {
  run grep -F 'Resume the Scrum workflow from the SessionStart resume summary.' \
    "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  run grep -F 'delegate a targeted investigation to scrum-explorer' \
    "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 0 ]
  run grep -F 'Reconcile PBI statuses in backlog.json against actual project state' \
    "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -ne 0 ]
}
