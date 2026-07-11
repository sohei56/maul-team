#!/usr/bin/env bats
# tests/unit/test_lib_time.bats
#
# Exercises scripts/lib/time.sh — the shared now_epoch / iso_utc_now helpers
# used by scripts/autonomous/watchdog.sh and scripts/stall-watchdog.sh.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT
  TIME_LIB="$PROJECT_ROOT/scripts/lib/time.sh"
  export TIME_LIB
}

@test "time.sh: now_epoch emits a plausible epoch integer" {
  run bash -c "source '$TIME_LIB' && now_epoch"
  [ "$status" -eq 0 ]
  # Pure digits, and in a sane range (after 2020-01-01 = 1577836800).
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 1577836800 ]
}

@test "time.sh: SCRUM_NOW_EPOCH pins now_epoch" {
  run bash -c "SCRUM_NOW_EPOCH=1234567890 bash -c \"source '$TIME_LIB' && now_epoch\""
  [ "$status" -eq 0 ]
  [ "$output" = "1234567890" ]
}

@test "time.sh: iso_utc_now emits ISO-8601 UTC (Z suffix)" {
  run bash -c "source '$TIME_LIB' && iso_utc_now"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "time.sh: iso_utc_now ignores SCRUM_NOW_EPOCH (real-clock timestamps)" {
  # Log/report timestamps must stay truthful even when "now" is pinned for
  # comparisons — matches both daemons' historical behavior.
  run bash -c "SCRUM_NOW_EPOCH=0 bash -c \"source '$TIME_LIB' && iso_utc_now\""
  [ "$status" -eq 0 ]
  [ "$output" != "1970-01-01T00:00:00Z" ]
  [[ "$output" =~ ^[0-9]{4}- ]]
}

@test "time.sh: double-sourcing is a no-op (guard)" {
  run bash -c "source '$TIME_LIB' && source '$TIME_LIB' && now_epoch"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}
