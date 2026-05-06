#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/cleanup.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/cleanup.XXXXXX")"
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
{"pbi_id":"pbi-001","phase":"merged","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "cleanup: removes worktree and branch" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
  [ ! -d .scrum/worktrees/pbi-001 ]
  run git branch --list pbi/pbi-001
  [ -z "$output" ]
}

@test "cleanup: idempotent — second call clean" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
}

@test "cleanup: refuses if phase not in {merged, escalated}" {
  jq '.phase = "ready_to_merge"' .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -ne 0 ]
}
