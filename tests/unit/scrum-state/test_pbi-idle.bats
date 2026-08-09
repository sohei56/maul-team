#!/usr/bin/env bats
# tests/unit/scrum-state/test_pbi-idle.bats — exercises
# scripts/scrum/pbi-idle.sh, the read-only per-PBI liveness reader the Scrum
# Master's 10-minute health check calls instead of improvising stat/date
# arithmetic.
#
# The wrapper is always invoked through its scripts/scrum/ path with the cwd
# set to a sandbox project root, because `.scrum` is cwd-relative.
#
# The BSD/GNU stat split is not re-tested here — it lives in
# lib/activity.sh and is covered by test_lib-activity.bats plus CI running on
# both OSes; the shims there pin the selection logic only.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WRAPPER="$PROJECT_ROOT/scripts/scrum/pbi-idle.sh"
  ACTIVITY_LIB="$PROJECT_ROOT/scripts/scrum/lib/activity.sh"
  TEST_TMP="$(mktemp -d /tmp/claude/pbi-idle-test.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/pbi-idle-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Helper: set mtime of a file/dir to "ageMinutesAgo".
# Test-only helper, mirrored in tests/unit/scrum-state/test_lib-activity.bats
# and tests/unit/test_stall_watchdog.bats.
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

# Helper: epoch of a path's mtime, via the same lib the wrapper reads, so
# boundary cases can pin SCRUM_NOW_EPOCH relative to real on-disk state.
mtime_epoch() {
  bash -c "source '$ACTIVITY_LIB' && mtime_of '$1'"
}

# Helper: write a backlog with the given "<id> <status>" pairs.
seed_backlog() {
  local out=".scrum/backlog.json" first=1
  printf '{"items":[' > "$out"
  while [ "$#" -ge 2 ]; do
    [ "$first" -eq 1 ] || printf ',' >> "$out"
    first=0
    printf '{"id":"%s","status":"%s"}' "$1" "$2" >> "$out"
    shift 2
  done
  printf ']}\n' >> "$out"
}

# Helper: the data rows (meta lines stripped) of the last `run`.
data_rows() {
  printf '%s\n' "$output" | grep -v '^#' || true
}

# --- preconditions ----------------------------------------------------------

@test "pbi-idle: a missing backlog fails loudly with E_FILE_MISSING (67)" {
  # Deliberately the inverse of the daemon's silent-empty contract: answering
  # "nothing is stale" because the backlog is unreadable is the same class of
  # false negative the wrapper exists to kill.
  run "$WRAPPER"
  [ "$status" -eq 67 ]
  [[ "$output" == *"E_FILE_MISSING"* ]]
}

@test "pbi-idle: an unparseable backlog fails with E_SCHEMA (65)" {
  printf 'not json at all\n' > .scrum/backlog.json
  run "$WRAPPER"
  [ "$status" -eq 65 ]
  [[ "$output" == *"E_SCHEMA"* ]]
}

@test "pbi-idle: run from outside the project root fails 67" {
  seed_backlog pbi-001 in_progress_impl
  mkdir -p sub
  cd sub || exit 1
  run "$WRAPPER"
  [ "$status" -eq 67 ]
}

# --- selection --------------------------------------------------------------

@test "pbi-idle: no in-flight PBI yields an all-zero summary and no rows" {
  seed_backlog pbi-001 refined pbi-002 done pbi-003 escalated
  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == "# summary in_flight=0 fresh=0 stale=0 uninitialized=0" ]]
  [ -z "$(data_rows)" ]
}

@test "pbi-idle: in_progress_merge is excluded, other in_progress_* are not" {
  seed_backlog pbi-001 in_progress_design pbi-002 in_progress_merge \
    pbi-003 in_progress_ut_run
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002 .scrum/pbi/pbi-003
  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pbi-001"* ]]
  [[ "$output" != *"pbi-002"* ]]
  [[ "$output" == *"pbi-003"* ]]
  [[ "$output" == *"in_flight=2"* ]]
}

# --- verdicts ---------------------------------------------------------------

@test "pbi-idle: a PBI with no artifact dir is uninitialized, never fresh" {
  # The 0 sentinel means "never observed". Reporting it as fresh (or as idle
  # 0s) is exactly the failure this wrapper exists to prevent.
  seed_backlog pbi-001 in_progress_impl
  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(data_rows)" = "$(printf 'pbi-001\tin_progress_impl\t0\t-\t-\tuninitialized')" ]
  [[ "$output" == *"uninitialized=1"* ]]
  [[ "$output" != *"fresh=1"* ]]
}

@test "pbi-idle: a just-touched PBI is fresh" {
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001
  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$(data_rows)" == *"fresh" ]]
  [[ "$output" == *"fresh=1 stale=0 uninitialized=0"* ]]
}

@test "pbi-idle: a PBI quiet for 40 minutes is stale at the default threshold" {
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 40
  local e
  e="$(mtime_epoch .scrum/pbi/pbi-001)"

  run env SCRUM_NOW_EPOCH=$((e + 2400)) "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(data_rows)" = "$(printf 'pbi-001\tin_progress_impl\t%s\t2400\t40\tstale' "$e")" ]
}

@test "pbi-idle: idle exactly at the threshold is fresh, one second past is stale" {
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001
  local e
  e="$(mtime_epoch .scrum/pbi/pbi-001)"

  run env SCRUM_NOW_EPOCH=$((e + 600)) "$WRAPPER" --threshold-minutes 10
  [ "$status" -eq 0 ]
  [[ "$(data_rows)" == *"600	10	fresh" ]]

  run env SCRUM_NOW_EPOCH=$((e + 601)) "$WRAPPER" --threshold-minutes 10
  [ "$status" -eq 0 ]
  [[ "$(data_rows)" == *"601	10	stale" ]]
}

@test "pbi-idle: --threshold-minutes 0 makes any elapsed second stale" {
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001
  local e
  e="$(mtime_epoch .scrum/pbi/pbi-001)"

  run env SCRUM_NOW_EPOCH=$((e + 1)) "$WRAPPER" --threshold-minutes 0
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# now=$((e + 1)) threshold_minutes=0" ]]
  [[ "$(data_rows)" == *"1	0	stale" ]]
}

@test "pbi-idle: a backwards clock prints negative idle as measured, unclamped" {
  # Clamping a negative idle to 0 is the very shape this tool exists to
  # remove: it would read as "active right now".
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001
  local e
  e="$(mtime_epoch .scrum/pbi/pbi-001)"

  run env SCRUM_NOW_EPOCH=$((e - 300)) "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(data_rows)" = "$(printf 'pbi-001\tin_progress_impl\t%s\t-300\t-5\tfresh' "$e")" ]
}

@test "pbi-idle: fresh worktree activity keeps a stale artifact dir fresh" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  seed_backlog pbi-001 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001 .scrum/worktrees/pbi-001
  set_mtime_ago .scrum/pbi/pbi-001 60
  git -C .scrum/worktrees/pbi-001 init -q
  echo "wip" > .scrum/worktrees/pbi-001/wip.txt

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$(data_rows)" == *"fresh" ]]
}

@test "pbi-idle: SCRUM_NOW_EPOCH is the clock seam reported in the header" {
  seed_backlog pbi-001 done
  run env SCRUM_NOW_EPOCH=1700000000 "$WRAPPER" --threshold-minutes 42
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# now=1700000000 threshold_minutes=42" ]
}

# --- summary / exit contract ------------------------------------------------

@test "pbi-idle: summary counts survive the loop (one of each verdict)" {
  # Regression pin: feeding the snapshot through a pipe puts the loop in a
  # Bash 3.2 subshell and every counter comes back 0.
  seed_backlog pbi-001 in_progress_impl pbi-002 in_progress_design \
    pbi-003 in_progress_ut_run
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002
  set_mtime_ago .scrum/pbi/pbi-002 60

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(data_rows | wc -l | tr -d ' ')" = "3" ]
  [[ "${lines[${#lines[@]}-1]}" == "# summary in_flight=3 fresh=1 stale=1 uninitialized=1" ]]
}

@test "pbi-idle: exits 0 even when everything is stale" {
  # Staleness is data, not an error — a nonzero exit would let a `set -e` or
  # `&&` habit swallow the finding.
  seed_backlog pbi-001 in_progress_impl pbi-002 in_progress_impl
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002
  set_mtime_ago .scrum/pbi/pbi-001 90
  set_mtime_ago .scrum/pbi/pbi-002 90

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh=0 stale=2 uninitialized=0"* ]]
}

@test "pbi-idle: every data row carries exactly 6 tab-separated fields" {
  seed_backlog pbi-001 in_progress_impl pbi-002 in_progress_design \
    pbi-003 in_progress_pbi_review
  mkdir -p .scrum/pbi/pbi-001 .scrum/pbi/pbi-002
  set_mtime_ago .scrum/pbi/pbi-002 60

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  local malformed
  malformed="$(printf '%s\n' "$output" | awk -F'\t' '!/^#/ && NF != 6')"
  [ -z "$malformed" ]
}

# --- argument validation ----------------------------------------------------

@test "pbi-idle: an unknown flag fails E_INVALID_ARG (64)" {
  seed_backlog pbi-001 in_progress_impl
  run "$WRAPPER" --idle-minutes 10
  [ "$status" -eq 64 ]
  [[ "$output" == *"E_INVALID_ARG"* ]]
}

@test "pbi-idle: a non-integer or negative threshold fails 64" {
  seed_backlog pbi-001 in_progress_impl
  run "$WRAPPER" --threshold-minutes 7.5
  [ "$status" -eq 64 ]
  run "$WRAPPER" --threshold-minutes -5
  [ "$status" -eq 64 ]
  run "$WRAPPER" --threshold-minutes ten
  [ "$status" -eq 64 ]
  run "$WRAPPER" --threshold-minutes
  [ "$status" -eq 64 ]
}

@test "pbi-idle: a positional argument fails 64" {
  seed_backlog pbi-001 in_progress_impl
  run "$WRAPPER" pbi-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"E_INVALID_ARG"* ]]
}
