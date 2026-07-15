#!/usr/bin/env bats
# tests/unit/scrum-state/test_begin-impl-round.bats — atomic, idempotent
# wrapper that owns `impl_round` advancement. Replaces agent-side `n+1` arithmetic.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/begin-impl-round.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/begin-impl-round.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{
  "pbi_id": "pbi-001",
  "design_round": 1,
  "impl_round": 0,
  "design_status": "pass",
  "impl_status": "pending",
  "ut_status": "pending",
  "coverage_status": "pending",
  "escalation_reason": null,
  "started_at": "2026-05-02T12:00:00Z",
  "updated_at": "2026-05-02T12:00:00Z"
}
EOF
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

set_state() { # field value [field value ...]
  local jq_expr="."
  while [ "$#" -ge 2 ]; do
    case "$2" in
      ''|*[!0-9]*) jq_expr="$jq_expr | .$1 = \"$2\"" ;;
      *)          jq_expr="$jq_expr | .$1 = $2" ;;
    esac
    shift 2
  done
  jq "$jq_expr" .scrum/pbi/pbi-001/state.json > .scrum/pbi/pbi-001/state.json.tmp
  mv .scrum/pbi/pbi-001/state.json.tmp .scrum/pbi/pbi-001/state.json
}

set_backlog_status() {
  jq --arg s "$1" '(.items[] | select(.id == "pbi-001")).status = $s' .scrum/backlog.json > .scrum/backlog.json.tmp
  mv .scrum/backlog.json.tmp .scrum/backlog.json
}

state_field() {
  jq -r --arg f "$1" '.[$f]' .scrum/pbi/pbi-001/state.json
}

backlog_status() {
  jq -r '.items[] | select(.id == "pbi-001") | .status' .scrum/backlog.json
}

run_begin() {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/begin-impl-round.sh" pbi-001
}

@test "begin-impl-round: first entry from in_progress_design → Round 1" {
  set_backlog_status in_progress_design
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ "$(state_field impl_round)" = "1" ]
  [ "$(state_field impl_status)" = "pending" ]
  [ "$(state_field ut_status)" = "pending" ]
  [ "$(backlog_status)" = "in_progress_impl" ]
}

@test "begin-impl-round: internal retry from in_progress_pbi_review → Round N+1" {
  set_state impl_round 2 impl_status fail ut_status pass
  set_backlog_status in_progress_pbi_review
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  [ "$(state_field impl_round)" = "3" ]
  [ "$(state_field impl_status)" = "pending" ]
  [ "$(state_field ut_status)" = "pending" ]
  [ "$(backlog_status)" = "in_progress_impl" ]
}

@test "begin-impl-round: internal retry from in_progress_ut_run → Round N+1" {
  set_state impl_round 1 impl_status pass ut_status fail
  set_backlog_status in_progress_ut_run
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ "$(state_field impl_round)" = "2" ]
}

@test "begin-impl-round: rejects illegal pre-state (cross_review)" {
  # Sprint-end cross-review is audit-only and never reverts a PBI, so
  # cross_review is no longer a legal re-entry pre-state. (The Integrity
  # stage reverts by transitioning to in_progress_impl BEFORE calling
  # this wrapper — see the test below.)
  set_state impl_round 2 impl_status pass ut_status pass
  set_backlog_status cross_review
  run_begin
  [ "$status" -eq 64 ]
  [[ "$output" == *"illegal pre-state"* ]]
}

@test "begin-impl-round: Integrity-stage revert pre-set in_progress_impl → still advances" {
  # integrity-stage.md Step I-5b calls update-backlog-status.sh ...
  # in_progress_impl BEFORE the conductor re-enters and calls
  # begin-impl-round.sh. The wrapper must still advance the counter.
  set_state impl_round 2 impl_status pass ut_status pass
  set_backlog_status in_progress_impl
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  [ "$(state_field impl_round)" = "3" ]
}

@test "begin-impl-round: idempotent — impl_status=pending AND impl_round>0 returns current Round" {
  # Crash-recovery scenario: a prior begin-impl-round.sh call wrote
  # impl_round=3 / impl_status=pending. Re-spawn calls again. Must NOT
  # double-increment.
  set_state impl_round 3 impl_status pending ut_status pending
  set_backlog_status in_progress_impl
  before_updated_at="$(state_field updated_at)"
  sleep 1
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  [ "$(state_field impl_round)" = "3" ]
  # updated_at must NOT have advanced — no write happened
  [ "$(state_field updated_at)" = "$before_updated_at" ]
}

@test "begin-impl-round: first entry edge — impl_round=0 AND impl_status=pending → Round 1 (no false idempotency)" {
  # The idempotency rule requires impl_round > 0 — this case proves
  # init-pbi-state.sh's seed (impl_round=0, impl_status=pending) is
  # treated as "first entry", not "Round 0 in progress".
  set_state impl_round 0 impl_status pending
  set_backlog_status in_progress_design
  run_begin
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ "$(state_field impl_round)" = "1" ]
}

@test "begin-impl-round: rejects illegal pre-state (done)" {
  set_backlog_status done
  run_begin
  [ "$status" -eq 64 ]
  [[ "$output" == *"illegal pre-state"* ]]
}

@test "begin-impl-round: rejects illegal pre-state (awaiting_cross_review)" {
  set_backlog_status awaiting_cross_review
  run_begin
  [ "$status" -eq 64 ]
  [[ "$output" == *"illegal pre-state"* ]]
}

@test "begin-impl-round: rejects illegal pre-state (escalated)" {
  set_backlog_status escalated
  run_begin
  [ "$status" -eq 64 ]
}

@test "begin-impl-round: rejects illegal pre-state (in_progress_merge)" {
  set_backlog_status in_progress_merge
  run_begin
  [ "$status" -eq 64 ]
}

@test "begin-impl-round: rejects bad pbi-id" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/begin-impl-round.sh" "BAD ID"
  [ "$status" -eq 64 ]
}

@test "begin-impl-round: rejects missing state.json" {
  rm -f .scrum/pbi/pbi-001/state.json
  set_backlog_status in_progress_design
  run_begin
  [ "$status" -eq 67 ]
  [[ "$output" == *"E_FILE_MISSING"* ]]
}

@test "begin-impl-round: rejects PBI not in backlog" {
  set_backlog_status in_progress_design
  # Strip the only PBI from backlog while leaving the file structure valid
  jq '.items = []' .scrum/backlog.json > .scrum/backlog.json.tmp
  mv .scrum/backlog.json.tmp .scrum/backlog.json
  run_begin
  [ "$status" -eq 64 ]
  [[ "$output" == *"not found in backlog"* ]]
}

@test "begin-impl-round: rejects missing backlog.json" {
  rm -f .scrum/backlog.json
  run_begin
  [ "$status" -eq 67 ]
}

@test "begin-impl-round: requires exactly one arg" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/begin-impl-round.sh"
  [ "$status" -eq 64 ]
}

@test "begin-impl-round: updates updated_at on mutation" {
  set_backlog_status in_progress_design
  before="$(state_field updated_at)"
  sleep 1
  run_begin
  [ "$status" -eq 0 ]
  after="$(state_field updated_at)"
  [ "$before" != "$after" ]
}

@test "begin-impl-round: ut_status is reset even if previously pass" {
  # Defends the round contract that BOTH stage statuses start pending
  # in every new Round.
  set_state impl_round 2 impl_status pass ut_status pass
  set_backlog_status in_progress_ut_run
  run_begin
  [ "$status" -eq 0 ]
  [ "$(state_field impl_status)" = "pending" ]
  [ "$(state_field ut_status)" = "pending" ]
}
