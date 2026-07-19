#!/usr/bin/env bats
# script-compose.bats — Integration tests for script composition
# Tests scrum-start.sh prerequisite checking, setup-user.sh file copying,
# and statusline.sh output format.

load '../test_helper/common-setup'

setup() {
  setup_temp_dir
  export PROJECT_ROOT
}

teardown() {
  teardown_temp_dir
}

# --- scrum-start.sh prerequisite checks ---

@test "scrum-start.sh exits 1 when claude is not on PATH" {
  # Create a restricted PATH without claude
  run env PATH="/usr/bin:/bin" bash "$PROJECT_ROOT/scrum-start.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude Code CLI not found"* ]]
}

@test "scrum-start.sh sets Agent Teams flag process-scoped (no global export needed)" {
  # Agent Teams env var is set inline by scrum-start.sh when launching claude,
  # so the script no longer checks for or requires a global export.
  # This test verifies the inline env var pattern is present in the script.
  run grep -c "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude" "$PROJECT_ROOT/scrum-start.sh"
  [ "$output" -ge 1 ]
}

# --- setup-user.sh file copying ---

@test "setup-user.sh copies agent definitions to .claude/agents/" {
  skip "requires full prerequisites (claude, python, textual, watchdog)"
  cd "$TEMP_DIR"
  run bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ -f ".claude/agents/scrum-master.md" ]
  [ -f ".claude/agents/developer.md" ]
}

@test "setup-user.sh copies skill definitions to .claude/skills/" {
  skip "requires full prerequisites"
  cd "$TEMP_DIR"
  run bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ -f ".claude/skills/sprint-planning/SKILL.md" ]
  [ -f ".claude/skills/spawn-teammates/SKILL.md" ]
  [ -f ".claude/skills/requirement-definition/SKILL.md" ]
}

@test "setup-user.sh creates settings.json with hook config" {
  skip "requires full prerequisites"
  cd "$TEMP_DIR"
  run bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ -f ".claude/settings.json" ]
  run jq '.hooks.SessionStart' ".claude/settings.json"
  assert_success
}

# --- statusline.sh output format ---

@test "statusline.sh outputs 3 lines with no state files" {
  cd "$TEMP_DIR"
  run bash "$PROJECT_ROOT/scripts/statusline.sh" < /dev/null
  assert_success
  # Should have 3 lines
  line_count="$(echo "$output" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 3 ]
}

@test "statusline.sh shows 'No active Sprint' when no sprint file" {
  cd "$TEMP_DIR"
  mkdir -p .scrum
  cat > .scrum/state.json << 'EOF'
{
  "product_goal": "Test",
  "current_sprint_id": null,
  "phase": "backlog_created",
  "created_at": "2026-03-01T10:00:00Z",
  "updated_at": "2026-03-01T10:00:00Z"
}
EOF
  run bash "$PROJECT_ROOT/scripts/statusline.sh" < /dev/null
  assert_success
  [[ "$output" == *"No active Sprint"* ]]
}

@test "statusline.sh shows backlog info when backlog exists" {
  cd "$TEMP_DIR"
  mkdir -p .scrum
  cat > .scrum/state.json << 'EOF'
{
  "product_goal": "Test",
  "current_sprint_id": null,
  "phase": "backlog_created",
  "created_at": "2026-03-01T10:00:00Z",
  "updated_at": "2026-03-01T10:00:00Z"
}
EOF
  cat > .scrum/backlog.json << 'EOF'
{
  "product_goal": "Test",
  "items": [
    {"id": "pbi-001", "title": "Test PBI", "description": "", "acceptance_criteria": [], "status": "draft", "priority": 1, "sprint_id": null, "implementer_id": null, "design_doc_paths": [], "review_doc_path": null, "depends_on_pbi_ids": [], "ux_change": false, "parent_pbi_id": null, "created_at": "2026-03-01T10:00:00Z", "updated_at": "2026-03-01T10:00:00Z"}
  ],
  "next_pbi_id": 2
}
EOF
  run bash "$PROJECT_ROOT/scripts/statusline.sh" < /dev/null
  assert_success
  [[ "$output" == *"Backlog: 1 items"* ]]
  [[ "$output" == *"1 draft"* ]]
}

@test "statusline.sh excludes cancelled PBIs from the Sprint total" {
  cd "$TEMP_DIR"
  mkdir -p .scrum
  cat > .scrum/state.json << 'EOF'
{
  "product_goal": "Test",
  "current_sprint_id": "sprint-1",
  "phase": "pbi_pipeline_active",
  "created_at": "2026-03-01T10:00:00Z",
  "updated_at": "2026-03-01T10:00:00Z"
}
EOF
  cat > .scrum/sprint.json << 'EOF'
{
  "id": "sprint-1",
  "goal": "Test goal",
  "status": "active",
  "developers": []
}
EOF
  cat > .scrum/backlog.json << 'EOF'
{
  "product_goal": "Test",
  "items": [
    {"id": "pbi-001", "title": "Done PBI", "status": "done", "sprint_id": "sprint-1"},
    {"id": "pbi-002", "title": "Active PBI", "status": "in_progress_impl", "sprint_id": "sprint-1"},
    {"id": "pbi-003", "title": "Cancelled PBI", "status": "cancelled", "sprint_id": "sprint-1"}
  ],
  "next_pbi_id": 4
}
EOF
  run bash "$PROJECT_ROOT/scripts/statusline.sh" < /dev/null
  assert_success
  # cancelled is descoped work: total counts 2, not 3 (matches
  # rollover-sprint.sh and dashboard/app.py semantics).
  [[ "$output" == *"1/2 PBIs done"* ]]
}

# --- 13-value status SSOT: direct-write through wrappers ---

# These tests compose multiple wrappers (update-backlog-status / update-pbi-state /
# mark-pbi-ready-to-merge / mark-pbi-merged / mark-pbi-merge-failure) and verify
# the new flow: status is written directly, no phase field, no derived projection.

setup_status_sandbox() {
  cd "$TEMP_DIR" || return 1
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog sprint; do
    cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/
  done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","started_at":"2026-05-06T10:00:00Z","updated_at":"2026-05-06T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"refined","demo_plan":"run x"}]}
EOF
}

@test "compose: update-backlog-status accepts every value of the 13-value enum" {
  setup_status_sandbox
  for s in draft refined blocked \
           in_progress_design in_progress_impl in_progress_pbi_review \
           in_progress_ut_run in_progress_merge \
           awaiting_cross_review cross_review escalated done cancelled; do
    run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
      "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 "$s"
    [ "$status" -eq 0 ]
    run jq -r '.items[0].status' .scrum/backlog.json
    [ "$output" = "$s" ]
  done
}

@test "compose: update-pbi-state rejects 'phase' field (no longer in schema)" {
  setup_status_sandbox
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase design
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown field"* ]]
}

@test "compose: mark-pbi-ready-to-merge sets backlog status=in_progress_merge" {
  setup_status_sandbox
  # Need a real worktree+commit to satisfy mark-pbi-ready-to-merge.
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-06T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-06T10:00:00Z"}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo body > .scrum/worktrees/pbi-001/f.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: f"

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
}

@test "compose: mark-pbi-merged sets backlog status=awaiting_cross_review" {
  setup_status_sandbox
  # Pre-load state.json with the fields mark-pbi-merged requires (head/branch/etc.)
  jq '.head_sha = "abcdef0" | .branch = "pbi/pbi-001" | .worktree = ".scrum/worktrees/pbi-001" | .base_sha = "1111111" | .paths_touched = ["a"] | .ready_at = "2026-05-06T11:00:00Z"' \
    .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_merge

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
}

@test "compose: mark-pbi-merge-failure (3rd) sets backlog status=escalated + escalation_reason" {
  setup_status_sandbox
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" pbi-001 in_progress_merge
  # Bump the counter to 2 directly so the next failure is the 3rd.
  jq '.merge_failure_count = 2' .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 conflict abcdef0 "src/a"
  [ "$status" -eq 0 ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "conflict" ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merge_conflict" ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "escalated" ]
}

# --- setup-user.sh: runtime-doc subset + manifest-owned pruning ---
#
# These exercise the full setup-user.sh end-to-end (unlike the skipped copy
# tests above) by shadowing only the three prerequisite binaries with stubs,
# so the deploy/prune logic runs while real coreutils (cp, grep, jq, awk …)
# stay intact. Stubs are PREPENDED to PATH — they never replace it.
make_prereq_stubs() {
  local bin="$TEMP_DIR/stubbin"
  mkdir -p "$bin"
  # claude: presence is all check_claude_cli requires.
  printf '#!/usr/bin/env bash\necho "stub-claude 9.9.9"\n' > "$bin/claude"
  # python3: report a >=3.9 version for the version probe; make every
  # `import <pkg>` succeed so check_python_prereqs skips the pip install path.
  cat > "$bin/python3" <<'PY'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *version_info*) echo "3.12"; exit 0 ;;
  esac
done
exit 0
PY
  # tmux: presence skips the auto-install branch (and any sudo apt-get).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/tmux"
  chmod +x "$bin/claude" "$bin/python3" "$bin/tmux"
  echo "$bin"
}

@test "setup-user.sh deploys .claude/docs subset and writes .maul-manifest" {
  local bin; bin="$(make_prereq_stubs)"
  cd "$TEMP_DIR"
  run env PATH="$bin:$PATH" bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ "$status" -eq 0 ]

  # Runtime-doc subset mirrors the source subtree under .claude/docs/.
  [ -f ".claude/docs/data-model.md" ]
  [ -f ".claude/docs/autonomous-mode.md" ]
  [ -f ".claude/docs/contracts/agent-interfaces.md" ]
  [ -f ".claude/docs/contracts/sub-agents.md" ]

  # Manifest exists, carries the versioned header, and lists the docs.
  [ -f ".claude/.maul-manifest" ]
  run grep -q '^# maul-team deploy manifest v[0-9]' ".claude/.maul-manifest"
  assert_success
  run grep -Fxq ".claude/docs/data-model.md" ".claude/.maul-manifest"
  assert_success
  run grep -Fxq ".claude/docs/contracts/agent-interfaces.md" ".claude/.maul-manifest"
  assert_success
  # A regular deployed agent is tracked too.
  run grep -Fxq ".claude/agents/scrum-master.md" ".claude/.maul-manifest"
  assert_success
  # Non-.claude deploys are intentionally NOT tracked.
  run grep -q "docs/contracts/scrum-state" ".claude/.maul-manifest"
  assert_failure
}

@test "setup-user.sh prunes stale framework files on redeploy but keeps user files" {
  local bin; bin="$(make_prereq_stubs)"
  cd "$TEMP_DIR"
  run env PATH="$bin:$PATH" bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ "$status" -eq 0 ]

  # Simulate framework files that existed in a PRIOR version: present on disk
  # AND recorded in the old manifest (so the next deploy is entitled to prune).
  echo "stale" > ".claude/agents/removed-agent.md"
  printf '%s\n' ".claude/agents/removed-agent.md" >> ".claude/.maul-manifest"
  mkdir -p ".claude/skills/old-skill"
  echo "stale" > ".claude/skills/old-skill/SKILL.md"
  printf '%s\n' ".claude/skills/old-skill/SKILL.md" >> ".claude/.maul-manifest"

  # A user-created file under .claude/skills/ — never in any manifest.
  mkdir -p ".claude/skills/my-notes"
  echo "mine" > ".claude/skills/my-notes/NOTES.md"

  run env PATH="$bin:$PATH" bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ "$status" -eq 0 ]

  # Stale framework file + stale (renamed) skill are pruned…
  [ ! -f ".claude/agents/removed-agent.md" ]
  [ ! -f ".claude/skills/old-skill/SKILL.md" ]
  # …and its now-empty skill dir is removed.
  [ ! -d ".claude/skills/old-skill" ]
  # User-authored file (and its dir) survive untouched.
  [ -f ".claude/skills/my-notes/NOTES.md" ]
  # A genuine framework agent is still present after the redeploy.
  [ -f ".claude/agents/scrum-master.md" ]
}

# --- setup-user.sh: space-safe deploy from an extracted (non-git) framework ---
#
# The Mac app extracts the bundled framework to
# "~/Library/Application Support/MaulTeam/framework-<ver>/" — a path with a
# SPACE and no .git. A word-splitting copy_tree once copied NOTHING from such
# a path while exiting 0 (skills used a quoted loop and kept deploying), so
# targets silently ran new skills against stale .scrum/scripts wrappers.
# These tests deploy from a spaced, git-less framework copy end-to-end.
make_spaced_framework() {
  # Mirror the app-extracted layout: working-tree content (NOT git archive —
  # uncommitted fixes must be under test), no .git, space in the path.
  local fw="$TEMP_DIR/Application Support/framework"
  mkdir -p "$fw"
  local d
  for d in agents skills hooks rules docs scripts; do
    cp -R "$PROJECT_ROOT/$d" "$fw/"
  done
  cp "$PROJECT_ROOT/.scrum-config.example.json" "$fw/"
  echo "$fw"
}

@test "setup-user.sh deploys wrappers/agents/hooks/rules from a path with spaces" {
  local bin; bin="$(make_prereq_stubs)"
  local fw; fw="$(make_spaced_framework)"
  mkdir -p "$TEMP_DIR/target"
  cd "$TEMP_DIR/target"

  run env PATH="$bin:$PATH" bash "$fw/scripts/setup-user.sh"
  [ "$status" -eq 0 ]

  # The copy_tree-deployed classes — every one of these was silently skipped
  # by the word-splitting bug.
  [ -x ".scrum/scripts/update-backlog-status.sh" ]
  [ -x ".scrum/scripts/set-backlog-item-field.sh" ]
  [ -f ".scrum/scripts/lib/queries.sh" ]
  [ -x ".scrum/scripts/migrations/001-legacy-to-ssot.sh" ]
  [ -f ".claude/agents/scrum-master.md" ]
  [ -x ".claude/hooks/stop-dispatch.sh" ]
  [ -f ".claude/hooks/lib/validate.sh" ]
  [ -f ".claude/rules/scrum-context.md" ]
  [ -f "scripts/lib/codex-invoke.sh" ]

  # The deployed wrapper must carry the current contract, not a stale one.
  run grep -q "demo_plan" ".scrum/scripts/set-backlog-item-field.sh"
  assert_success
}

@test "setup-user.sh deploy stamp prefers .framework-rev and never inherits an ancestor repo sha" {
  local bin; bin="$(make_prereq_stubs)"
  local fw; fw="$(make_spaced_framework)"

  # Extracted bundle, no marker: not a git toplevel → sha must be unknown
  # (never the sha of whatever repo happens to sit above the extraction dir).
  mkdir -p "$TEMP_DIR/target-a"
  cd "$TEMP_DIR/target-a"
  run env PATH="$bin:$PATH" bash "$fw/scripts/setup-user.sh"
  [ "$status" -eq 0 ]
  assert_json_match ".scrum/deploy-stamp.json" ".framework_sha" "unknown"

  # With the make-app.sh content marker present, the stamp carries it.
  printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$fw/.framework-rev"
  mkdir -p "$TEMP_DIR/target-b"
  cd "$TEMP_DIR/target-b"
  run env PATH="$bin:$PATH" bash "$fw/scripts/setup-user.sh"
  [ "$status" -eq 0 ]
  assert_json_match ".scrum/deploy-stamp.json" ".framework_sha" "0123456789ab"
  assert_json_match ".scrum/deploy-stamp.json" ".framework_dirty" "false"
}

@test "setup-user.sh skips prune when previous manifest has an unsafe path" {
  local bin; bin="$(make_prereq_stubs)"
  cd "$TEMP_DIR"
  run env PATH="$bin:$PATH" bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ "$status" -eq 0 ]

  # A stale-but-safe entry that WOULD be pruned, plus a traversal path that
  # must poison the whole prune step.
  echo "stale" > ".claude/agents/removed-agent.md"
  printf '%s\n' ".claude/agents/removed-agent.md" >> ".claude/.maul-manifest"
  printf '%s\n' "../evil" >> ".claude/.maul-manifest"

  run env PATH="$bin:$PATH" bash "$PROJECT_ROOT/scripts/setup-user.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe path"* ]]
  # Prune skipped ⇒ the otherwise-stale file is still on disk.
  [ -f ".claude/agents/removed-agent.md" ]
}
