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
{"items":[{"id":"pbi-001","title":"x","status":"refined"}]}
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
