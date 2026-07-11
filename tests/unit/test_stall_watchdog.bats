#!/usr/bin/env bats
# tests/unit/test_stall_watchdog.bats
#
# Exercises scripts/stall-watchdog.sh with --once and a PATH-stubbed tmux.
# The stub records every `tmux ...` invocation to $TMUX_LOG so each scenario
# can assert whether a nudge was sent.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT
  WATCHDOG="$PROJECT_ROOT/scripts/stall-watchdog.sh"
  export WATCHDOG

  TEST_TMP="$(mktemp -d /tmp/claude/stall-watchdog-test.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/stall-watchdog-test.XXXXXX")"
  export TEST_TMP

  # tmux stub: writes every call's arg list to $TMUX_LOG, returns success
  # for has-session and send-keys.
  STUB_DIR="$TEST_TMP/stub"
  mkdir -p "$STUB_DIR"
  TMUX_LOG="$TEST_TMP/tmux.log"
  export TMUX_LOG
  : > "$TMUX_LOG"
  cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
# Test stub: log every call and exit 0. has-session is special-cased to
# allow tests to force "session gone" via TMUX_HAS_SESSION_FAIL=1.
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session)
    if [ "${TMUX_HAS_SESSION_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_DIR/tmux"
  # PATH prepends stub dir so plain `tmux` resolves to our stub.
  export PATH="$STUB_DIR:$PATH"
  # Also export the explicit override so the script does not depend on PATH.
  export STALL_TMUX_BIN="$STUB_DIR/tmux"

  # Project skeleton
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi .scrum/logs

  # Minimal runtime.json
  cat > .scrum/runtime.json <<'JSON'
{
  "tmux_session": "test-session",
  "sm_pane_id": "%0",
  "started_at": "2026-06-12T00:00:00Z",
  "stall_watchdog_pid": null
}
JSON

  # Default config: short thresholds so tests don't have to back-date a long time.
  # idle=1min, cooldown=1min, poll=1s.
  cat > .scrum/config.json <<'JSON'
{
  "stall_watchdog": {
    "enabled": true,
    "idle_threshold_minutes": 1,
    "cooldown_minutes": 1,
    "poll_interval_seconds": 1
  }
}
JSON
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    if [ "${BATS_TEST_PRESERVE_TMP:-0}" = "1" ]; then
      echo "preserved: $TEST_TMP" >&3
    else
      rm -rf "$TEST_TMP"
    fi
  fi
}

# Helper: count how many tmux send-keys calls (excluding the trailing Enter)
# carry the STALL-WATCHDOG marker. The script invokes send-keys twice per
# nudge (the message, then Enter), so the marker count == nudge count.
nudge_count() {
  # grep -c exits 1 with output "0" on zero matches, which combined with a
  # naive `|| echo 0` would emit "0\n0". Use grep without -c and count
  # matching lines via wc -l so we always emit exactly one integer.
  if [ -f "$TMUX_LOG" ]; then
    grep -F 'STALL-WATCHDOG' "$TMUX_LOG" 2>/dev/null | wc -l | tr -d ' \t'
  else
    echo 0
  fi
}

# Helper: backlog seeded with N in-progress PBIs (status=in_progress_impl).
seed_backlog_inflight() {
  local n="$1" i items=""
  for ((i = 1; i <= n; i++)); do
    if [ -n "$items" ]; then items="${items},"; fi
    items="${items}{\"id\":\"pbi-$(printf '%03d' "$i")\",\"status\":\"in_progress_impl\"}"
  done
  printf '{"items":[%s]}\n' "$items" > .scrum/backlog.json
}

# Helper: set mtime of a file/dir to "ageMinutesAgo".
set_mtime_ago() {
  # set_mtime_ago <path> <minutes_ago>
  local target="$1" minutes_ago="$2"
  # touch -t accepts [[CC]YY]MMDDhhmm[.ss]. Use date arithmetic both ways.
  local ts
  if ts="$(date -v -"${minutes_ago}"M +%Y%m%d%H%M.%S 2>/dev/null)"; then
    : # BSD date
  elif ts="$(date -d "${minutes_ago} minutes ago" +%Y%m%d%H%M.%S 2>/dev/null)"; then
    : # GNU date
  else
    return 1
  fi
  touch -t "$ts" "$target"
}

# --------------------------------------------------------------------------
# (a) in-flight == 0 → no nudge
# --------------------------------------------------------------------------
@test "stall-watchdog: zero in-flight PBIs → no nudge" {
  # No backlog.json at all → in_flight = 0
  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
}

# --------------------------------------------------------------------------
# (b) in-flight > 0 but activity is fresh → no nudge
# --------------------------------------------------------------------------
@test "stall-watchdog: in-flight with fresh activity → no nudge" {
  seed_backlog_inflight 1
  # dashboard.json freshly touched → last_activity = now
  printf '{"events":[]}\n' > .scrum/dashboard.json
  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
}

# --------------------------------------------------------------------------
# (c) in-flight > 0 and activity stale beyond threshold → exactly one nudge
# --------------------------------------------------------------------------
@test "stall-watchdog: stale activity beyond threshold → one nudge" {
  seed_backlog_inflight 2
  printf '{"events":[]}\n' > .scrum/dashboard.json
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002

  # Push every activity signal 10 minutes into the past — exceeds 1-min idle
  # threshold by a wide margin.
  set_mtime_ago .scrum/dashboard.json 10
  set_mtime_ago .scrum/pbi 10
  set_mtime_ago .scrum/pbi/pbi-001 10
  set_mtime_ago .scrum/pbi/pbi-002 10

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  # Exactly one nudge (the script sends the message + an Enter, but only
  # the message line carries the STALL-WATCHDOG marker).
  [ "$(nudge_count)" -eq 1 ]
  # The recorded send-keys call must target the configured SM pane.
  grep -F 'send-keys -t %0' "$TMUX_LOG" | grep -q 'STALL-WATCHDOG'
  # State file recorded a non-zero epoch.
  [ -f .scrum/logs/stall-watchdog.state ]
  state_val="$(cat .scrum/logs/stall-watchdog.state)"
  [ "$state_val" -gt 0 ]
}

# --------------------------------------------------------------------------
# (d) cooldown suppresses a second nudge inside the window
# --------------------------------------------------------------------------
@test "stall-watchdog: re-run within cooldown does not re-nudge" {
  seed_backlog_inflight 1
  printf '{"events":[]}\n' > .scrum/dashboard.json
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/dashboard.json 10
  set_mtime_ago .scrum/pbi 10
  set_mtime_ago .scrum/pbi/pbi-001 10

  # First run nudges.
  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 1 ]

  # Second run, same stale mtimes, immediately after → must be suppressed by
  # cooldown (1 minute) since the state file just got "now".
  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 1 ]   # still one
}

# --------------------------------------------------------------------------
# (d2) per-PBI stall: global activity fresh but one PBI stale → nudge names it
# --------------------------------------------------------------------------
@test "stall-watchdog: fresh global activity but one stale PBI → per-PBI nudge" {
  seed_backlog_inflight 2
  # dashboard.json freshly touched → the GLOBAL detector stays quiet.
  printf '{"events":[]}\n' > .scrum/dashboard.json
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002
  # pbi-001 active, pbi-002 quiet for 10 minutes (> 1-min threshold).
  set_mtime_ago .scrum/pbi/pbi-002 10

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 1 ]
  grep -F 'per-PBI stall' "$TMUX_LOG" | grep -q 'pbi-002'
  # The active PBI must NOT be named as stale.
  run bash -c "grep -F 'per-PBI stall' '$TMUX_LOG' | grep 'pbi-001('"
  [ "$status" -ne 0 ]
}

# --------------------------------------------------------------------------
# (d3) per-PBI: stale artifact dir but fresh dirty file in the worktree
#      → the worktree edit counts as activity, no nudge
# --------------------------------------------------------------------------
@test "stall-watchdog: stale PBI dir but fresh worktree edit → no nudge" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  seed_backlog_inflight 1
  printf '{"events":[]}\n' > .scrum/dashboard.json
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 10

  # Worktree with one fresh uncommitted file — a live sub-agent edit.
  mkdir -p .scrum/worktrees/pbi-001
  git -C .scrum/worktrees/pbi-001 init -q
  echo "wip" > .scrum/worktrees/pbi-001/wip.txt

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
}

# --------------------------------------------------------------------------
# (d4) per-PBI: PBI dir missing entirely (pipeline not initialized) → skipped
# --------------------------------------------------------------------------
@test "stall-watchdog: in-flight PBI without artifact dir → per-PBI check skipped" {
  seed_backlog_inflight 1
  # Global activity fresh; .scrum/pbi/pbi-001 never created.
  printf '{"events":[]}\n' > .scrum/dashboard.json

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
}

# --------------------------------------------------------------------------
# (e) config enabled=false → immediate exit, no nudge attempted
# --------------------------------------------------------------------------
@test "stall-watchdog: disabled in config → no-op exit" {
  seed_backlog_inflight 1
  printf '{"events":[]}\n' > .scrum/dashboard.json
  set_mtime_ago .scrum/dashboard.json 999
  jq '.stall_watchdog.enabled = false' .scrum/config.json > .scrum/config.json.tmp \
    && mv .scrum/config.json.tmp .scrum/config.json

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
}

# --------------------------------------------------------------------------
# (f) runtime.json missing → log only, exit 0 (do not crash)
# --------------------------------------------------------------------------
@test "stall-watchdog: missing runtime.json → exit 0 with log" {
  rm -f .scrum/runtime.json
  seed_backlog_inflight 1

  run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
  [ -f .scrum/logs/stall-watchdog.log ]
  grep -q 'runtime.json missing' .scrum/logs/stall-watchdog.log
}

# --------------------------------------------------------------------------
# (f2) SCRUM_NOW_EPOCH (shared scripts/lib/time.sh seam) pins "now"
# --------------------------------------------------------------------------
@test "stall-watchdog: SCRUM_NOW_EPOCH pins now → fresh activity looks stale, nudge fires" {
  seed_backlog_inflight 1
  mkdir -p .scrum/pbi/pbi-001
  # dashboard.json freshly touched — with the real clock this would be "no
  # nudge" (scenario b). Pin now 10 minutes ahead so idle > 1-min threshold.
  printf '{"events":[]}\n' > .scrum/dashboard.json
  SCRUM_NOW_EPOCH=$(( $(date +%s) + 600 )) run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 1 ]
}

# --------------------------------------------------------------------------
# (f3) legacy STALL_NOW_EPOCH alias still maps onto the shared seam
# --------------------------------------------------------------------------
@test "stall-watchdog: legacy STALL_NOW_EPOCH override still honored" {
  seed_backlog_inflight 1
  mkdir -p .scrum/pbi/pbi-001
  printf '{"events":[]}\n' > .scrum/dashboard.json
  STALL_NOW_EPOCH=$(( $(date +%s) + 600 )) run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 1 ]
}

# --------------------------------------------------------------------------
# (g) tmux session vanished → exit 0 (clean shutdown)
# --------------------------------------------------------------------------
@test "stall-watchdog: tmux has-session fails → exit 0 (team gone)" {
  seed_backlog_inflight 1
  printf '{"events":[]}\n' > .scrum/dashboard.json
  TMUX_HAS_SESSION_FAIL=1 run "$WATCHDOG" "$TEST_TMP" --once
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -eq 0 ]
  grep -q 'tmux session test-session no longer exists' .scrum/logs/stall-watchdog.log
}
