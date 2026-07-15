#!/usr/bin/env bash
# scripts/lib/time.sh — shared time helpers for the two watchdog daemons
# (scripts/autonomous/watchdog.sh and scripts/stall-watchdog.sh).
#
# Both daemons run in-place from the framework repo (scrum-start.sh launches
# them via $SCRIPT_DIR/scripts/...), so this lib always travels with them —
# same deployment reasoning as scripts/lib/jq-read.sh.
#
# Test hook (env var; harmless in production):
#   SCRUM_NOW_EPOCH — when non-empty, now_epoch emits this value verbatim
#                     instead of the wall clock. Single, eval-free override
#                     seam shared by both daemons (replaces the legacy
#                     per-daemon AUTON_NOW_CMD / STALL_NOW_EPOCH seams).
#
# Bash 3.2 compatible. shellcheck clean.

# Guard against double-sourcing.
# shellcheck disable=SC2317
if [ "${_TIME_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_TIME_SH_LOADED=1

# now_epoch — emit current unix epoch seconds (or $SCRUM_NOW_EPOCH when set).
now_epoch() {
  if [ -n "${SCRUM_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$SCRUM_NOW_EPOCH"
  else
    date +%s
  fi
}

# iso_utc_now — emit the current UTC time as ISO-8601 (2026-01-02T03:04:05Z).
# Always reads the real clock (log/report timestamps must stay truthful even
# under a pinned SCRUM_NOW_EPOCH — matches both daemons' historical behavior).
iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}
