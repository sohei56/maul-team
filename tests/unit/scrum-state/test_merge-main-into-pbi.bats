#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/merge-main-into-pbi.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/merge-main-into-pbi.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do
    cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/
  done
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress_impl"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/file.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: file"
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "merge-main-into-pbi: clean merge advances PBI HEAD" {
  # Add a divergent commit on main that does not conflict.
  echo "main-side" > main_only.txt
  git add main_only.txt
  git commit -q -m "main: add main_only.txt"
  PBI_HEAD_BEFORE="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "merged cleanly"

  PBI_HEAD_AFTER="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  [ "$PBI_HEAD_BEFORE" != "$PBI_HEAD_AFTER" ]
  # File from main should be present in PBI worktree after merge
  [ -f .scrum/worktrees/pbi-001/main_only.txt ]
}

@test "merge-main-into-pbi: already-ancestor is a no-op" {
  PBI_HEAD_BEFORE="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no-op"
  [ "$PBI_HEAD_BEFORE" = "$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)" ]
}

@test "merge-main-into-pbi: conflict leaves worktree in merge state, exits non-zero" {
  # Both main and PBI branch touch file.txt with different content.
  echo "main-version" > file.txt
  git add file.txt
  git commit -q -m "main: rewrite file.txt"

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "CONFLICT"
  echo "$output" | grep -q "file.txt"

  # Worktree should be in mid-merge state (MERGE_HEAD exists)
  [ -f .scrum/worktrees/pbi-001/.git ] || [ -d .scrum/worktrees/pbi-001/.git ]
  GIT_DIR="$(git -C .scrum/worktrees/pbi-001 rev-parse --git-dir)"
  [ -f "$GIT_DIR/MERGE_HEAD" ]
}

@test "merge-main-into-pbi: refuses bad pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" not-a-pbi
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "bad pbi-id"
}

@test "merge-main-into-pbi: refuses missing worktree" {
  rm -rf .scrum/worktrees/pbi-001
  git worktree prune 2>/dev/null || true
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
}

@test "merge-main-into-pbi: refuses when .scrum/ is tracked in git" {
  git add -f .scrum/sprint.json
  git commit -q -m "track sprint.json"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "tracked in git"
}

@test "merge-main-into-pbi: refuses when PBI worktree has uncommitted tracked changes" {
  echo "dirty" >> .scrum/worktrees/pbi-001/file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-main-into-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "uncommitted tracked changes"
}
