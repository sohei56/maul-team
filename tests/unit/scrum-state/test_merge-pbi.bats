#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/merge-pbi.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/merge-pbi.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
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
{"items":[{"id":"pbi-001","title":"x","status":"in_progress_ut_run"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/file.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: file"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  # mark-pbi-ready-to-merge has set backlog status to in_progress_merge.
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "merge-pbi: success path — merges, verifies, sets awaiting_cross_review, cleans up" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
  run git log --oneline main
  echo "$output" | grep -q "merge: pbi-001"
  [ ! -d .scrum/worktrees/pbi-001 ]
}

@test "merge-pbi: artifact_missing — paths_touched contains a file deleted in branch" {
  # Simulate a paths_touched entry that doesn't end up on HEAD
  jq '.paths_touched = ["nonexistent.txt"]' .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "artifact_missing" ]
  # Backlog status remains in_progress_merge (single failure < 3, no escalation).
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
  # main HEAD should be back to original
  run git log --oneline main
  ! echo "$output" | grep -q "merge: pbi-001"
}

@test "merge-pbi: merge_conflict — main has competing change on the same file" {
  echo "world" > file.txt
  git add file.txt
  git commit -q -m "main: competing change to file.txt"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"

  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]

  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "conflict" ]
  run jq -r '.merge_failure.paths | index("file.txt")' .scrum/pbi/pbi-001/state.json
  [ "$output" != "null" ]

  # main HEAD restored — no merge commit lingers from a half-completed attempt.
  run git rev-parse HEAD
  [ "$output" = "$PRE_MAIN_HEAD" ]

  # PBI branch and worktree still exist (rollback preserves them for the
  # Developer to rebase + retry).
  [ -d .scrum/worktrees/pbi-001 ]
  run git show-ref --verify --quiet refs/heads/pbi/pbi-001
  [ "$status" -eq 0 ]
}

@test "merge-pbi: refuses non-in_progress_merge status" {
  jq '(.items[] | select(.id=="pbi-001")).status = "in_progress_design"' .scrum/backlog.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
}

@test "merge-pbi: refuses when current branch is not main" {
  PRE_HEAD="$(git rev-parse HEAD)"
  git checkout -q -b feature/test
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli SCRUM_SKIP_QUALITY_GATE=1 "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must run with 'main' checked out"
  # Side-effect-free: HEAD unchanged on the feature branch
  [ "$(git rev-parse HEAD)" = "$PRE_HEAD" ]
}

@test "merge-pbi: refuses when .scrum/ is tracked in git" {
  git add -f .scrum/sprint.json
  git commit -q -m "track sprint.json"
  PRE_HEAD="$(git rev-parse HEAD)"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli SCRUM_SKIP_QUALITY_GATE=1 "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "tracked in git"
  # Side-effect-free: HEAD unchanged
  [ "$(git rev-parse HEAD)" = "$PRE_HEAD" ]
}
