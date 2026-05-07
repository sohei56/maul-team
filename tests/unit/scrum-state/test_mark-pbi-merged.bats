#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-merged.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-merged.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","head_sha":"abcdef0","branch":"pbi/pbi-001","worktree":".scrum/worktrees/pbi-001","base_sha":"1111111","paths_touched":["a"],"ready_at":"2026-05-04T11:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress_merge"}]}
EOF
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-merged: sets merged_sha+merged_at on state.json; mirrors to backlog and flips status to awaiting_cross_review" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -eq 0 ]
  run jq -r '.merged_sha' .scrum/pbi/pbi-001/state.json
  [ "$output" = "abcdef0" ]
  run jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json
  [ "$output" = "0" ]
  run jq -r '.items[0].merged_sha' .scrum/backlog.json
  [ "$output" = "abcdef0" ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "awaiting_cross_review" ]
}

@test "mark-merged: clears prior merge_failure record on success" {
  # Seed a stale merge_failure record from a prior retry.
  jq '. + {merge_failure: {kind: "conflict", paths: ["a"], pre_head_at_failure: "2222222"}, merge_failure_count: 1}' \
    .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" \
    && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -eq 0 ]
  run jq -r 'has("merge_failure")' .scrum/pbi/pbi-001/state.json
  [ "$output" = "false" ]
  run jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json
  [ "$output" = "0" ]
}

@test "mark-merged: refuses if backlog status is not in_progress_merge" {
  jq '(.items[] | select(.id=="pbi-001")).status = "in_progress_design"' .scrum/backlog.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/backlog.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -ne 0 ]
}

@test "mark-merged: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 NOT_HEX
  [ "$status" -ne 0 ]
}
