#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-fail.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-fail.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"ready_to_merge","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"review"}]}
EOF
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-failure conflict: sets merge_conflict + records paths + increments counter" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 conflict abcdef0 "src/a,src/b"
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merge_conflict" ]
  run jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "conflict" ]
  run jq -r '.merge_failure.paths | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "2" ]
}

@test "mark-failure regression: stores report_path" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 regression abcdef0 ".scrum/pbi/pbi-001/qg.log"
  [ "$status" -eq 0 ]
  run jq -r '.merge_failure.report_path' .scrum/pbi/pbi-001/state.json
  [ "$output" = ".scrum/pbi/pbi-001/qg.log" ]
}

@test "mark-failure: 3rd consecutive failure escalates" {
  # set counter to 2 first
  jq '.merge_failure_count = 2' .scrum/pbi/pbi-001/state.json > "${TMPDIR:-/tmp}/x" && mv "${TMPDIR:-/tmp}/x" .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 conflict abcdef0 "src/a"
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "escalated" ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "stagnation" ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "blocked" ]
}
