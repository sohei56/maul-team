#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-rtm.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-rtm.XXXXXX")"
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
{"pbi_id":"pbi-001","phase":"impl_ut","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/src.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "first"
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-ready-to-merge: sets phase, head_sha, paths_touched, ready_at" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "ready_to_merge" ]
  run jq -r '.paths_touched | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.paths_touched[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = "src.txt" ]
  run jq -r '.head_sha' .scrum/pbi/pbi-001/state.json
  EXPECTED="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  [ "$output" = "$EXPECTED" ]
  run jq -r '.ready_at' .scrum/pbi/pbi-001/state.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "mark-ready-to-merge: backlog status projects to review" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "review" ]
}

@test "mark-ready-to-merge: refuses if no commits diverge from base" {
  # Reset branch to base so diff is empty.
  WT=.scrum/worktrees/pbi-001
  git -C "$WT" reset --hard HEAD~1
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
}
