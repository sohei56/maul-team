#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/commit-pbi.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/commit-pbi.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"impl_ut","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "commit-pbi: commits and updates head_sha" {
  echo "hello" > .scrum/worktrees/pbi-001/file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: add file"
  [ "$status" -eq 0 ]
  EXPECTED="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  run jq -r '.head_sha' .scrum/pbi/pbi-001/state.json
  [ "$output" = "$EXPECTED" ]
}

@test "commit-pbi: refuses if branch is not pbi/<id>" {
  git -C .scrum/worktrees/pbi-001 checkout -b rogue
  echo "x" > .scrum/worktrees/pbi-001/file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "msg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "branch"
}

@test "commit-pbi: noops cleanly when nothing to commit" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "msg"
  [ "$status" -eq 0 ]
}
