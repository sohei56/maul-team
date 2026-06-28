#!/usr/bin/env bats
# tests/unit/scrum-state/test_rollover-sprint.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/rollover-sh.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/rollover-sh.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  SCRIPT="$PROJECT_ROOT/scripts/scrum/rollover-sprint.sh"
  HIST="$TEST_TMP/.scrum/sprint-history.json"
  SPRINT="$TEST_TMP/.scrum/sprint.json"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Write a sprint.json with the given status/goal. Tests bypass the scrum-state
# guard (a Claude Code hook, not active under bats), so a direct write is fine.
write_sprint() {
  local status="$1" goal="$2"
  jq -n --arg status "$status" --arg goal "$goal" '{
    id: "sprint-001", goal: $goal, type: "development", status: $status,
    base_sha: "deadbeef", base_sha_captured_at: "2026-06-01T00:00:00Z",
    developers: ["dev-001-s1"],
    started_at: "2026-06-01T00:00:00Z",
    completed_at: "2026-06-14T00:00:00Z"
  }' > "$SPRINT"
}

write_backlog() {
  # 3 PBIs in sprint-001 (2 done), 1 PBI in another sprint (ignored).
  jq -n '{items: [
    {id: "pbi-001", sprint_id: "sprint-001", status: "done"},
    {id: "pbi-002", sprint_id: "sprint-001", status: "done"},
    {id: "pbi-003", sprint_id: "sprint-001", status: "in_progress_impl"},
    {id: "pbi-004", sprint_id: "sprint-002", status: "done"}
  ]}' > "$TEST_TMP/.scrum/backlog.json"
}

@test "rollover-sprint: complete sprint is archived and sprint.json removed" {
  write_sprint complete "Ship the MVP"
  write_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  # The Sprint id is echoed on stdout (last line; the progress note goes to stderr).
  [ "${lines[-1]}" = "sprint-001" ]
  # sprint.json cleared so init-sprint.sh can create the next Sprint.
  [ ! -f "$SPRINT" ]
  # history records the Sprint once.
  [ -f "$HIST" ]
  run jq -r '.sprints | length' "$HIST"
  [ "$output" = "1" ]
  run jq -r '.sprints[0].id' "$HIST"
  [ "$output" = "sprint-001" ]
  run jq -r '.sprints[0].goal' "$HIST"
  [ "$output" = "Ship the MVP" ]
}

@test "rollover-sprint: derives PBI counts from the Sprint Backlog" {
  write_sprint complete "Counts"
  write_backlog
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -r '.sprints[0].pbis_total' "$HIST"
  [ "$output" = "3" ]
  run jq -r '.sprints[0].pbis_completed' "$HIST"
  [ "$output" = "2" ]
}

@test "rollover-sprint: preserves started_at / completed_at / type" {
  write_sprint complete "Timestamps"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -r '.sprints[0].type' "$HIST"
  [ "$output" = "development" ]
  run jq -r '.sprints[0].started_at' "$HIST"
  [ "$output" = "2026-06-01T00:00:00Z" ]
  run jq -r '.sprints[0].completed_at' "$HIST"
  [ "$output" = "2026-06-14T00:00:00Z" ]
}

@test "rollover-sprint: null goal falls back to a placeholder" {
  jq -n '{
    id: "sprint-001", goal: null, type: "development", status: "complete",
    developers: [], started_at: "2026-06-01T00:00:00Z",
    completed_at: "2026-06-14T00:00:00Z"
  }' > "$SPRINT"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -r '.sprints[0].goal' "$HIST"
  [ "$output" = "(no goal recorded)" ]
}

@test "rollover-sprint: omits PBI counts when backlog.json is absent" {
  write_sprint complete "No backlog"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -e '.sprints[0] | has("pbis_total") | not' "$HIST"
  [ "$status" -eq 0 ]
  run jq -e '.sprints[0] | has("pbis_completed") | not' "$HIST"
  [ "$status" -eq 0 ]
}

@test "rollover-sprint: refuses a non-complete sprint and leaves it untouched" {
  write_sprint active "In flight"
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"refuse to roll over"* ]]
  [[ "$output" == *"status=active"* ]]
  # sprint.json preserved; no history written.
  [ -f "$SPRINT" ]
  [ ! -f "$HIST" ]
}

@test "rollover-sprint: idempotent no-op when sprint.json is absent" {
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to roll over"* ]]
  [ ! -f "$HIST" ]
}

@test "rollover-sprint: no duplicate when the Sprint is already in history" {
  write_sprint complete "Already archived"
  # Pre-seed history with this Sprint id (e.g. sprint-review archived it).
  env SCRUM_VALIDATOR_OVERRIDE=python \
    "$PROJECT_ROOT/scripts/scrum/append-sprint-history.sh" \
    --id sprint-001 --goal "Already archived" >/dev/null
  run env SCRUM_VALIDATOR_OVERRIDE=python "$SCRIPT"
  [ "$status" -eq 0 ]
  # append-sprint-history is idempotent on id → still exactly one entry…
  run jq -r '.sprints | length' "$HIST"
  [ "$output" = "1" ]
  # …and sprint.json is still cleared so the next Sprint can start.
  [ ! -f "$SPRINT" ]
}
