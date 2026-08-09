#!/usr/bin/env bats
# tests/unit/scrum-state/test_lib-activity.bats — exercises
# scripts/scrum/lib/activity.sh (mtime_of / max_mtime_recursive /
# pbi_activity_epoch / in_flight_snapshot), the shared PBI liveness signals.
#
# Every case sources the lib into a fresh subshell (test_lib_time.bats
# pattern) so the double-source guard cannot leak between tests.
#
# The BSD/GNU stat split is only *selected* here, via a PATH-shimmed stat: the
# real split is covered for free by CI running this suite on both macOS and
# Linux. The shim tests pin the selection logic (garbage output from the wrong
# stat flavor must never reach the caller as an epoch).

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  ACTIVITY_LIB="$PROJECT_ROOT/scripts/scrum/lib/activity.sh"
  BASH_BIN="$(command -v bash)"
  TEST_TMP="$(mktemp -d /tmp/claude/lib-activity-test.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/lib-activity-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Helper: set mtime of a file/dir to "ageMinutesAgo".
# Test-only helper, mirrored in tests/unit/test_stall_watchdog.bats.
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

# Helper: epoch of "N minutes ago", for freshness assertions.
epoch_ago() {
  echo $(($(date +%s) - ($1 * 60)))
}

# Helper: install a PATH-shimmed `stat` from the given body; echoes the dir.
stub_stat() {
  local dir="$TEST_TMP/stub-$$-${RANDOM}"
  mkdir -p "$dir"
  cat > "$dir/stat"
  chmod +x "$dir/stat"
  printf '%s\n' "$dir"
}

# --- mtime_of ---------------------------------------------------------------

@test "activity.sh: mtime_of on a missing path emits the 0 sentinel" {
  run bash -c "source '$ACTIVITY_LIB' && mtime_of '$TEST_TMP/nope'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "activity.sh: mtime_of on a real file emits its epoch" {
  local floor
  floor="$(epoch_ago 2)"
  : > file.txt
  run bash -c "source '$ACTIVITY_LIB' && mtime_of file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt "$floor" ]
}

@test "activity.sh: mtime_of falls back to GNU stat when the BSD form emits garbage" {
  # GNU stat reads `-f %m` as "filesystem status of a file named %m": a
  # multi-line block on stdout with a nonzero exit. It must be rejected by the
  # pure-integer guard, not concatenated with the real epoch.
  local dir
  dir="$(stub_stat <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -f) printf '  File: "%%m"\n    ID: 0  Namelen: 255  Type: ext2/ext3\n'; exit 1 ;;
  -c) printf '1700000000\n'; exit 0 ;;
esac
exit 1
STUB
)"
  : > file.txt
  run env PATH="$dir:$PATH" bash -c "source '$ACTIVITY_LIB' && mtime_of file.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "1700000000" ]
}

@test "activity.sh: mtime_of emits 0 when both stat flavors fail" {
  local dir
  dir="$(stub_stat <<'STUB'
#!/usr/bin/env bash
printf 'stat: cannot read file system information\nsecond line of noise\n'
exit 1
STUB
)"
  : > file.txt
  run env PATH="$dir:$PATH" bash -c "source '$ACTIVITY_LIB' && mtime_of file.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- max_mtime_recursive ----------------------------------------------------

@test "activity.sh: max_mtime_recursive on a missing dir emits the 0 sentinel" {
  run bash -c "source '$ACTIVITY_LIB' && max_mtime_recursive '$TEST_TMP/nope'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "activity.sh: max_mtime_recursive returns the newest mtime at any depth" {
  local floor
  floor="$(epoch_ago 2)"
  mkdir -p tree/a/b
  : > tree/a/b/deep.txt
  set_mtime_ago tree 60
  set_mtime_ago tree/a 60
  set_mtime_ago tree/a/b 60
  # Only the deepest file is fresh.
  touch tree/a/b/deep.txt

  run bash -c "source '$ACTIVITY_LIB' && max_mtime_recursive tree"
  [ "$status" -eq 0 ]
  [ "$output" -gt "$floor" ]
}

@test "activity.sh: an empty new subdir counts as activity" {
  # Documented behavior: the walk includes directories, so a stage that has
  # created its output dir but not written a file yet is still "active".
  local floor
  floor="$(epoch_ago 2)"
  mkdir -p tree/fresh-subdir
  set_mtime_ago tree 60

  run bash -c "source '$ACTIVITY_LIB' && max_mtime_recursive tree"
  [ "$status" -eq 0 ]
  [ "$output" -gt "$floor" ]
}

# --- pbi_activity_epoch -----------------------------------------------------

@test "activity.sh: pbi_activity_epoch emits 0 when the artifact dir is absent" {
  # The sentinel contract: 0 means "never observed", NOT "stale since 1970".
  mkdir -p .scrum/pbi
  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "activity.sh: pbi_activity_epoch with only an artifact dir returns its mtime" {
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 60
  local expected
  expected="$(bash -c "source '$ACTIVITY_LIB' && mtime_of .scrum/pbi/pbi-001")"

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "activity.sh: a fresh nested pipeline.log makes a stale PBI dir fresh" {
  local floor
  floor="$(epoch_ago 2)"
  mkdir -p .scrum/pbi/pbi-001/logs
  : > .scrum/pbi/pbi-001/logs/pipeline.log
  set_mtime_ago .scrum/pbi/pbi-001 60
  set_mtime_ago .scrum/pbi/pbi-001/logs 60
  touch .scrum/pbi/pbi-001/logs/pipeline.log

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" -gt "$floor" ]
}

@test "activity.sh: a fresh dirty worktree file beats a stale artifact dir" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  local floor
  floor="$(epoch_ago 2)"
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 60
  # No commit at all: freshness can only come from the untracked file.
  mkdir -p .scrum/worktrees/pbi-001
  git -C .scrum/worktrees/pbi-001 init -q
  echo "wip" > .scrum/worktrees/pbi-001/wip.txt

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" -gt "$floor" ]
}

@test "activity.sh: a fresh commit beats a stale artifact dir" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 60
  mkdir -p .scrum/worktrees/pbi-001
  git -C .scrum/worktrees/pbi-001 init -q
  echo "done" > .scrum/worktrees/pbi-001/src.txt
  git -C .scrum/worktrees/pbi-001 add src.txt
  git -C .scrum/worktrees/pbi-001 \
    -c user.email=t@example.com -c user.name=tester commit -q -m "work"
  # Clean tree → the commit timestamp is the only fresh signal.
  local ct
  ct="$(git -C .scrum/worktrees/pbi-001 log -1 --format=%ct)"

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" = "$ct" ]
}

@test "activity.sh: pbi_activity_epoch without git falls back to the dir mtime" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  # PATH stripped down to the coreutils the lib needs — `command -v git` must
  # fail and the worktree branch must be skipped, not crash. The worktree
  # carries a fresh commit, so a git that stayed reachable would return "now"
  # instead of the stale dir mtime and fail this assertion.
  local nogit t src
  nogit="$TEST_TMP/nogit"
  mkdir -p "$nogit"
  for t in stat find head cut; do
    src="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$nogit/$t"
  done
  mkdir -p .scrum/pbi/pbi-001 .scrum/worktrees/pbi-001
  git -C .scrum/worktrees/pbi-001 init -q
  echo "done" > .scrum/worktrees/pbi-001/src.txt
  git -C .scrum/worktrees/pbi-001 add src.txt
  git -C .scrum/worktrees/pbi-001 \
    -c user.email=t@example.com -c user.name=tester commit -q -m "work"
  set_mtime_ago .scrum/pbi/pbi-001 60
  local expected
  expected="$(bash -c "source '$ACTIVITY_LIB' && mtime_of .scrum/pbi/pbi-001")"

  run env PATH="$nogit" "$BASH_BIN" -c \
    "cd '$TEST_TMP' && source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "activity.sh: pbi_activity_epoch honors the scrum_dir argument" {
  # Artifacts live under alt/, nothing under .scrum/ → the argument, not a
  # hard-coded path, decides where we look.
  mkdir -p alt/pbi/pbi-001 .scrum/pbi
  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 alt"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001 .scrum"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "activity.sh: pbi_activity_epoch defaults scrum_dir to .scrum" {
  mkdir -p .scrum/pbi/pbi-001
  local expected
  expected="$(bash -c "source '$ACTIVITY_LIB' && mtime_of .scrum/pbi/pbi-001")"

  run bash -c "source '$ACTIVITY_LIB' && pbi_activity_epoch pbi-001"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# --- in_flight_snapshot -----------------------------------------------------

@test "activity.sh: in_flight_snapshot emits TSV for in_progress_* minus merge" {
  mkdir -p .scrum
  cat > .scrum/backlog.json <<'JSON'
{"items":[
  {"id":"pbi-001","status":"in_progress_impl"},
  {"id":"pbi-002","status":"in_progress_merge"},
  {"id":"pbi-003","status":"in_progress_design"},
  {"id":"pbi-004","status":"refined"},
  {"id":"pbi-005","status":"done"}
]}
JSON
  run bash -c "source '$ACTIVITY_LIB' && in_flight_snapshot .scrum/backlog.json"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf 'pbi-001\tin_progress_impl')" ]
  [ "${lines[1]}" = "$(printf 'pbi-003\tin_progress_design')" ]
}

@test "activity.sh: in_flight_snapshot is silently empty on a missing or broken backlog" {
  # The daemon contract: an unreadable backlog must not abort the poll loop.
  # (The read-only wrapper deliberately inverts this and fails loudly.)
  mkdir -p .scrum
  run bash -c "source '$ACTIVITY_LIB' && in_flight_snapshot .scrum/backlog.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'not json at all\n' > .scrum/backlog.json
  run bash -c "source '$ACTIVITY_LIB' && in_flight_snapshot .scrum/backlog.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- source guard -----------------------------------------------------------

@test "activity.sh: double-sourcing is a no-op (guard)" {
  run bash -c "source '$ACTIVITY_LIB' && source '$ACTIVITY_LIB' && mtime_of '$TEST_TMP'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}
