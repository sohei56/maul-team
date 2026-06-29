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

@test "merge-pbi: no regression command configured → success with WARN" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no merge regression command configured"
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
}

@test "merge-pbi: regression command passing → merge succeeds, no failure recorded" {
  cat > .scrum/config.json <<'EOF'
{"merge_regression":{"command":"true"}}
EOF
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
  run jq -r '.merge_failure // "absent"' .scrum/pbi/pbi-001/state.json
  [ "$output" = "absent" ]
}

@test "merge-pbi: regression command failing → records regression failure, rolls back main" {
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"
  cat > .scrum/config.json <<'EOF'
{"merge_regression":{"command":"echo boom >&2; exit 1"}}
EOF
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "regression" ]
  # main HEAD restored to pre-merge HEAD
  run git rev-parse HEAD
  [ "$output" = "$PRE_MAIN_HEAD" ]
  # log captured
  [ -f .scrum/pbi/pbi-001/merge-regression.log ]
  grep -q boom .scrum/pbi/pbi-001/merge-regression.log
  # backlog status still in_progress_merge (single failure < 3)
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
}

@test "merge-pbi: disjoint working-tree drift does NOT block the merge (P0-b) and is restored" {
  # A tracked file the merge never touches is dirtied on main. Historically
  # the blanket clean check refused ALL merges in this state, stranding
  # unrelated PBIs. The scoped check must let the merge proceed and the trap
  # must restore the drift afterward.
  echo "base" > other.txt; git add other.txt; git commit -q -m "main: other.txt"
  echo "DIRTY-DISJOINT" > other.txt   # uncommitted, disjoint from file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "stashed out-of-scope working-tree drift"
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
  git log --oneline main | grep -q "merge: pbi-001"
  # Out-of-scope drift restored verbatim.
  [ "$(cat other.txt)" = "DIRTY-DISJOINT" ]
}

@test "merge-pbi: COLLIDING working-tree drift still refuses (P0-b safety floor)" {
  # Drift on a path the merge WOULD modify must still block — git itself would
  # refuse to overwrite it, and proceeding could lose the change.
  echo "main-version" > file.txt; git add file.txt; git commit -q -m "main: file.txt"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"
  echo "DIRTY-COLLIDE" > file.txt    # same path the pbi-001 branch touches
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "files this merge modifies"
  # No merge commit; the colliding drift is left untouched (NOT stashed).
  [ "$(git rev-parse HEAD)" = "$PRE_MAIN_HEAD" ]
  [ "$(cat file.txt)" = "DIRTY-COLLIDE" ]
}

@test "merge-pbi: regression rollback PRESERVES disjoint drift (no git reset --hard data loss)" {
  # The critical safety property of stashing disjoint drift: a post-merge
  # rollback (`git reset --hard PRE_HEAD`) must not eat unrelated uncommitted
  # changes.
  echo "base" > other.txt; git add other.txt; git commit -q -m "main: other.txt"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"
  echo "DIRTY-DISJOINT" > other.txt
  cat > .scrum/config.json <<'EOF'
{"merge_regression":{"command":"exit 1"}}
EOF
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "regression" ]
  # Merge rolled back …
  [ "$(git rev-parse HEAD)" = "$PRE_MAIN_HEAD" ]
  # … but the disjoint drift survived the hard reset.
  [ "$(cat other.txt)" = "DIRTY-DISJOINT" ]
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
