#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/create-pbi-worktree.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/create-pbi-worktree.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  git init -q
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"design","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
}

teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "create-pbi-worktree: creates worktree, branch, symlink, and updates state" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
  [ -d .scrum/worktrees/pbi-001 ]
  [ -L .scrum/worktrees/pbi-001/.scrum ]
  run git -C .scrum/worktrees/pbi-001 rev-parse --abbrev-ref HEAD
  [ "$output" = "pbi/pbi-001" ]
  run jq -r '"\(.branch)|\(.worktree)|\(.base_sha)"' .scrum/pbi/pbi-001/state.json
  SHA="$(git rev-parse HEAD)"
  [ "$output" = "pbi/pbi-001|.scrum/worktrees/pbi-001|$SHA" ]
}

@test "create-pbi-worktree: refuses if sprint.base_sha is missing" {
  jq 'del(.base_sha)' .scrum/sprint.json > .scrum/sprint.json.tmp && mv .scrum/sprint.json.tmp .scrum/sprint.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -ne 0 ]
}

@test "create-pbi-worktree: refuses if pbi state missing" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-999
  [ "$status" -ne 0 ]
}

@test "create-pbi-worktree: idempotent — second call no-ops cleanly" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
}
