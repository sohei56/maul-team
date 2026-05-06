#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-merged.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-merged.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"ready_to_merge","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","head_sha":"abcdef0","branch":"pbi/pbi-001","worktree":".scrum/worktrees/pbi-001","base_sha":"1111111","paths_touched":["a"],"ready_at":"2026-05-04T11:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"review"}]}
EOF
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-merged: sets phase, merged_sha, merged_at; mirrors to backlog" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -eq 0 ]
  run jq -r '"\(.phase)|\(.merged_sha)"' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merged|abcdef0" ]
  run jq -r '.items[0].merged_sha' .scrum/backlog.json
  [ "$output" = "abcdef0" ]
}

@test "mark-merged: refuses if phase is not ready_to_merge" {
  jq '.phase = "design"' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -ne 0 ]
}

@test "mark-merged: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 NOT_HEX
  [ "$status" -ne 0 ]
}
