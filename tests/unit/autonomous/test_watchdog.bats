#!/usr/bin/env bats
# tests/unit/autonomous/test_watchdog.bats
#
# Exercises scripts/autonomous/watchdog.sh end-to-end with a stub `claude`
# binary so we don't make any network calls. The stub
# (tests/fixtures/autonomous/fake-claude.sh) consumes a scenario file that
# mutates .scrum/state.json / backlog.json / dashboard.json per call.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  export PROJECT_ROOT
  WATCHDOG="$PROJECT_ROOT/scripts/autonomous/watchdog.sh"
  export WATCHDOG
  FAKE_CLAUDE="$PROJECT_ROOT/tests/fixtures/autonomous/fake-claude.sh"
  export FAKE_CLAUDE

  TEST_TMP="$(mktemp -d /tmp/claude/watchdog-test.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/watchdog-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1

  mkdir -p .scrum

  # Seed state.json with a phase before "complete" so the loop runs.
  cat > .scrum/state.json <<'JSON'
{
  "phase": "requirements_sprint",
  "current_sprint_id": null,
  "product_goal": "test",
  "created_at": "2026-06-12T00:00:00Z",
  "updated_at": "2026-06-12T00:00:00Z"
}
JSON

  # Minimal backlog so progress-hash has something to anchor on.
  cat > .scrum/backlog.json <<'JSON'
{"items":[{"id":"pbi-001","status":"draft"}]}
JSON

  # Tight but realistic config so tests finish quickly.
  cat > .scrum/config.json <<'JSON'
{
  "po_mode": "agent",
  "autonomous": {
    "max_iterations": 5,
    "max_wall_clock_hours": 8,
    "max_sprints": 5,
    "max_consecutive_failures": 3,
    "stop_block_budget_per_phase": 8,
    "permission_mode": "dontAsk",
    "notify_command": null,
    "fallback_model": null
  }
}
JSON

  # autonomy.json — fresh run.
  cat > .scrum/autonomy.json <<'JSON'
{
  "run_id": "test-run",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": null,
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null,
  "updated_at": "2026-06-12T00:00:00Z"
}
JSON

  export AUTON_CLAUDE_BIN="$FAKE_CLAUDE"
  export AUTON_SLEEP_SCALE=0
  export FAKE_CLAUDE_SCENARIO="$TEST_TMP/scenario.json"
  export FAKE_CLAUDE_COUNTER="$TEST_TMP/call-count"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    # Set BATS_TEST_PRESERVE_TMP=1 to keep dirs for debugging.
    if [ "${BATS_TEST_PRESERVE_TMP:-0}" = "1" ]; then
      echo "preserved: $TEST_TMP" >&3
    else
      rm -rf "$TEST_TMP"
    fi
  fi
}

# --------------------------------------------------------------------------
# (a) Happy path: 2 iterations advance phase to complete → exit 0 + report
# --------------------------------------------------------------------------
@test "watchdog: reaches phase=complete after two iterations and writes report" {
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"phase_to": "backlog_created",
     "stdout_json": {"total_cost_usd": 1.5},
     "exit_code": 0},
    {"phase_to": "complete",
     "stdout_json": {"total_cost_usd": 0.5},
     "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  # Report should exist
  [ -f .scrum/reports/autonomous-run-test-run.md ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'complete'
  # total_cost_usd accumulated to 2.0 (1.5 + 0.5)
  cost="$(jq -r '.total_cost_usd' .scrum/autonomy.json)"
  awk -v c="$cost" 'BEGIN{exit !(c >= 1.99 && c <= 2.01)}'
  # iteration advanced to 2
  [ "$(jq -r '.iteration' .scrum/autonomy.json)" = "2" ]
}

# --------------------------------------------------------------------------
# (b) Stagnation: phase never changes, 3 consecutive failures → exit 1
# --------------------------------------------------------------------------
@test "watchdog: max_consecutive_failures triggers exit 1" {
  # No phase advance, no backlog churn — progress hash never changes after
  # iter 1 → iters 2, 3, 4 all count as failures.
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"stdout_json": {}, "exit_code": 0},
    {"stdout_json": {}, "exit_code": 0},
    {"stdout_json": {}, "exit_code": 0},
    {"stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 1 ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'max_consecutive_failures'
}

# --------------------------------------------------------------------------
# (c) Rate-limit detected via dashboard event → watchdog sleeps and retries;
#     iteration counter is NOT advanced. After the wait, the next call
#     succeeds (advances phase to complete), so the watchdog exits 0 and
#     last_failure preserves the rate-limit wait marker.
# --------------------------------------------------------------------------
@test "watchdog: rate_limit dashboard event triggers wait, not failure" {
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"stdout_json": {}, "exit_code": 0,
     "dashboard_events": [{"type": "stop_failure", "detail": "rate_limit exceeded"}]},
    {"phase_to": "complete", "stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'complete'
  # last_failure should reflect the rate-limit wait (never overwritten)
  reason="$(jq -r '.last_failure.reason // empty' .scrum/autonomy.json)"
  [ "$reason" = "rate_limit_wait" ]
}

# --------------------------------------------------------------------------
# (c2) Rate-limit detected via iter-N.json result envelope (subtype) →
#      same wait-and-retry behaviour.
# --------------------------------------------------------------------------
@test "watchdog: rate_limit in result envelope triggers wait, not failure" {
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"stdout_json": {"is_error": true, "subtype": "error_rate_limit",
                      "errors": ["Rate limit exceeded; reset in 60 seconds"]},
     "exit_code": 0},
    {"phase_to": "complete", "stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  reason="$(jq -r '.last_failure.reason // empty' .scrum/autonomy.json)"
  [ "$reason" = "rate_limit_wait" ]
}

# --------------------------------------------------------------------------
# (d) max_iterations safety valve → exit 2
# --------------------------------------------------------------------------
@test "watchdog: max_iterations safety valve → exit 2" {
  # Lower the cap to 2, supply 3 no-op calls (any iter beyond 2 trips it).
  jq '.autonomous.max_iterations = 2' .scrum/config.json > .scrum/config.json.tmp \
    && mv .scrum/config.json.tmp .scrum/config.json

  cat > scenario.json <<'JSON'
{
  "calls": [
    {"phase_to": "backlog_created", "stdout_json": {}, "exit_code": 0},
    {"phase_to": "sprint_planning", "stdout_json": {}, "exit_code": 0},
    {"stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 2 ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'max_iterations_exceeded'
}

# --------------------------------------------------------------------------
# (e) max_sprints safety valve is baseline-relative → exit 2 once
#     sprint-history reaches sprint_baseline + max_sprints.
# --------------------------------------------------------------------------
@test "watchdog: sprint-history reaching baseline+max_sprints → exit 2" {
  jq '.autonomous.max_sprints = 2' .scrum/config.json > .scrum/config.json.tmp \
    && mv .scrum/config.json.tmp .scrum/config.json

  # Simulate a resumed run whose baseline was 0 (persisted in autonomy.json).
  # With max_sprints=2 the limit is 0 + 2 = 2, and history already has 2
  # completed sprints → trip the valve on the very first safety-check.
  jq '.sprint_baseline = 0' .scrum/autonomy.json > .scrum/autonomy.json.tmp \
    && mv .scrum/autonomy.json.tmp .scrum/autonomy.json

  cat > .scrum/sprint-history.json <<'JSON'
{"sprints":[
  {"id":"sprint-001","status":"complete","goal":"a"},
  {"id":"sprint-002","status":"complete","goal":"b"}
]}
JSON

  cat > scenario.json <<'JSON'
{"calls": [{"stdout_json": {}, "exit_code": 0}]}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 2 ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'max_sprints_reached'
}

# --------------------------------------------------------------------------
# (e2) max_sprints is NOT a cumulative cap: a fresh run captures the
#      startup sprint-history length as the baseline, so pre-existing
#      Sprints do not trip the valve. history=2, max_sprints=2 → limit=4;
#      history stays 2 across the run → the loop advances to phase=complete.
# --------------------------------------------------------------------------
@test "watchdog: pre-existing sprints below baseline+max_sprints do not trip" {
  jq '.autonomous.max_sprints = 2' .scrum/config.json > .scrum/config.json.tmp \
    && mv .scrum/config.json.tmp .scrum/config.json

  # 2 sprints already in history, but no sprint_baseline recorded yet → the
  # watchdog captures baseline=2 at startup, so the limit is 4, not 2.
  cat > .scrum/sprint-history.json <<'JSON'
{"sprints":[
  {"id":"sprint-001","status":"complete","goal":"a"},
  {"id":"sprint-002","status":"complete","goal":"b"}
]}
JSON

  cat > scenario.json <<'JSON'
{"calls": [{"phase_to": "complete", "stdout_json": {}, "exit_code": 0}]}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  grep -F 'Exit reason' .scrum/reports/autonomous-run-test-run.md | grep -q 'complete'
  # baseline captured and persisted as the startup history length (2)
  [ "$(jq -r '.sprint_baseline' .scrum/autonomy.json)" = "2" ]
}

# --------------------------------------------------------------------------
# (f) lead_session_id is rewritten each iteration
# --------------------------------------------------------------------------
@test "watchdog: lead_session_id changes between iterations" {
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"phase_to": "backlog_created", "stdout_json": {}, "exit_code": 0},
    {"phase_to": "complete",        "stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  # We need to capture session ids per call. Wrap fake-claude.sh so it
  # records the --session-id argument it was passed each call.
  cat > capture-fake-claude.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
sid=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--session-id" ]; then sid="\$a"; break; fi
  prev="\$a"
done
printf '%s\n' "\$sid" >> "$TEST_TMP/session-ids.log"
exec "$FAKE_CLAUDE" "\$@"
EOF
  chmod +x capture-fake-claude.sh
  AUTON_CLAUDE_BIN="$TEST_TMP/capture-fake-claude.sh" run "$WATCHDOG"

  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/session-ids.log" ]
  # Two distinct session ids must have been captured.
  uniq_count="$(sort -u "$TEST_TMP/session-ids.log" | wc -l | tr -d ' ')"
  [ "$uniq_count" -eq 2 ]
}

# --------------------------------------------------------------------------
# (g) circuit_breaker_tripped non-null counts as failure and is then reset
# --------------------------------------------------------------------------
@test "watchdog: circuit_breaker_tripped counts as fail and is reset" {
  jq '.autonomous.max_consecutive_failures = 99 | .autonomous.max_iterations = 4' \
    .scrum/config.json > .scrum/config.json.tmp \
    && mv .scrum/config.json.tmp .scrum/config.json

  # The watchdog writes lead_session_id but the autonomy file's
  # circuit_breaker_tripped is set externally — for the stub we precreate it
  # so that the FIRST safety-valve check sees it.
  jq '.circuit_breaker_tripped = {"phase":"requirements_sprint","at":"2026-06-12T00:00:01Z"}' \
    .scrum/autonomy.json > .scrum/autonomy.json.tmp \
    && mv .scrum/autonomy.json.tmp .scrum/autonomy.json

  cat > scenario.json <<'JSON'
{
  "calls": [
    {"phase_to": "backlog_created", "stdout_json": {}, "exit_code": 0},
    {"phase_to": "complete",        "stdout_json": {}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  # After the run, circuit_breaker_tripped should be cleared (null).
  cb="$(jq -r '.circuit_breaker_tripped' .scrum/autonomy.json)"
  [ "$cb" = "null" ]
  # last_failure should record a "circuit_breaker" reason from iter 1.
  reason="$(jq -r '.last_failure.reason // empty' .scrum/autonomy.json)"
  [ "$reason" = "circuit_breaker" ]
}

# --------------------------------------------------------------------------
# (h) Missing autonomy.json → exit 3 (config error)
# --------------------------------------------------------------------------
@test "watchdog: exits 3 when .scrum/autonomy.json is missing" {
  rm -f .scrum/autonomy.json
  cat > scenario.json <<'JSON'
{"calls": [{"stdout_json": {}, "exit_code": 0}]}
JSON
  run "$WATCHDOG"
  [ "$status" -eq 3 ]
}

# --------------------------------------------------------------------------
# (i) total_cost_usd is recorded but not enforced (budget caps removed)
# --------------------------------------------------------------------------
@test "watchdog: total_cost_usd is accumulated for observability, not enforced" {
  # Two iterations spending plenty; previously this tripped a budget cap.
  # Now the run should complete normally and autonomy.json should hold the
  # sum.
  cat > scenario.json <<'JSON'
{
  "calls": [
    {"phase_to": "backlog_created", "stdout_json": {"total_cost_usd": 40}, "exit_code": 0},
    {"phase_to": "complete",        "stdout_json": {"total_cost_usd": 60}, "exit_code": 0}
  ]
}
JSON

  run "$WATCHDOG"
  [ "$status" -eq 0 ]
  cost="$(jq -r '.total_cost_usd' .scrum/autonomy.json)"
  awk -v c="$cost" 'BEGIN{exit !(c >= 99.99 && c <= 100.01)}'
}
