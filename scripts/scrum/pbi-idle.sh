#!/usr/bin/env bash
# scripts/scrum/pbi-idle.sh — how long has each in-flight PBI been quiet?
# Usage: pbi-idle.sh [--threshold-minutes N]
#
# Read-only. Reads `.scrum/backlog.json` (cwd-relative, like the rest of the
# wrapper family) plus the per-PBI activity signals in `lib/activity.sh`, and
# writes no state. The Scrum Master's periodic pipeline health check calls
# this instead of improvising `stat` / `date` arithmetic: a hand-rolled
# `$((NOW - X))` whose X came back empty evaluates to NOW-NOW=0 and reports a
# dead PBI as "0m quiet", suppressing the probe forever.
#
# Activity for one PBI is the newest of its artifact tree under
# `.scrum/pbi/<id>/` (state.json, pipeline.log, stage reviews), its worktree's
# last commit, and its worktree's dirty/untracked files.
#
# Output — `#`-prefixed meta lines around one tab-separated row per in-flight
# PBI (id, status, last_activity_epoch, idle_seconds, idle_minutes, verdict):
#
#   # now=1754700000 threshold_minutes=10
#   # id	status	last_activity_epoch	idle_seconds	idle_minutes	verdict
#   pbi-001	in_progress_impl	1754697600	2400	40	stale
#   # summary in_flight=1 fresh=0 stale=1 uninitialized=0
#
# verdict is one of:
#   fresh          idle_seconds <= threshold (the boundary second is fresh)
#   stale          idle_seconds > threshold — probe the owning Developer
#   uninitialized  no `.scrum/pbi/<id>/` exists, so no activity has ever been
#                  observed; both idle fields print `-`. Never "fresh".
#
# Idle seconds are printed as measured and never clamped: a negative value
# means the clock moved backwards, which is worth seeing rather than hiding.
#
# Exit 0 whether or not anything is stale — staleness is data, not an error,
# and a nonzero exit would let a `set -e` / `&&` habit drop the finding.
# 64 bad argument, 65 unparseable backlog, 67 missing backlog (this wrapper
# fails loudly where the stall-watchdog daemon stays silently empty: answering
# "nothing is stale" because the backlog could not be read is the same class
# of false negative as NOW-NOW=0).
#
# The default 10 matches the SM health-check cadence. The external
# stall-watchdog daemon's per-PBI backstop
# (`config.json.stall_watchdog.pbi_idle_threshold_minutes`) is a separate knob,
# deliberately set to fire later — see docs/data-model.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/activity.sh
source "$HERE/lib/activity.sh"

USAGE="usage: pbi-idle.sh [--threshold-minutes N]"
THRESHOLD_MINUTES=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold-minutes)
      [ "$#" -ge 2 ] || fail E_INVALID_ARG "--threshold-minutes needs a value. $USAGE"
      THRESHOLD_MINUTES="$2"
      shift 2
      ;;
    *)
      fail E_INVALID_ARG "unknown argument: $1. $USAGE"
      ;;
  esac
done
case "$THRESHOLD_MINUTES" in
  ''|*[!0-9]*)
    fail E_INVALID_ARG "--threshold-minutes must be a non-negative integer: $THRESHOLD_MINUTES"
    ;;
esac

SCRUM_DIR=".scrum"
BACKLOG="$SCRUM_DIR/backlog.json"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG not found (run from the project root)"
jq empty "$BACKLOG" >/dev/null 2>&1 || fail E_SCHEMA "$BACKLOG is not parseable JSON"

# Same override seam as scripts/lib/time.sh::now_epoch (that lib travels with
# the daemons, not with the deployed wrappers, so the one line is repeated).
NOW="${SCRUM_NOW_EPOCH:-$(date +%s)}"
THRESHOLD_SECONDS=$((THRESHOLD_MINUTES * 60))

printf '# now=%s threshold_minutes=%s\n' "$NOW" "$THRESHOLD_MINUTES"
printf '# id\tstatus\tlast_activity_epoch\tidle_seconds\tidle_minutes\tverdict\n'

TOTAL=0
FRESH=0
STALE=0
UNINIT=0
TAB="$(printf '\t')"
# The snapshot is fed in by heredoc, not by a pipe: a pipe runs the loop in a
# subshell under Bash 3.2 and every counter below would come back 0.
while IFS="$TAB" read -r id status; do
  [ -n "$status" ] || continue
  TOTAL=$((TOTAL + 1))
  if [ -n "$id" ]; then
    epoch="$(pbi_activity_epoch "$id" "$SCRUM_DIR")"
  else
    # An id-less item cannot be attributed to an artifact tree; `.scrum/pbi/`
    # itself would resolve to the whole tree's newest activity and read fresh.
    epoch=0
  fi
  if [ "$epoch" -eq 0 ]; then
    # The idle fields stay literal `-` so they cannot be misread as "0 seconds
    # quiet" and any arithmetic on them fails loudly. Changing `-` to 0
    # reintroduces the NOW-NOW=0 false negative.
    idle_seconds="-"
    idle_minutes="-"
    verdict="uninitialized"
    UNINIT=$((UNINIT + 1))
  else
    idle_seconds=$((NOW - epoch))
    idle_minutes=$((idle_seconds / 60))
    if [ "$idle_seconds" -gt "$THRESHOLD_SECONDS" ]; then
      verdict="stale"
      STALE=$((STALE + 1))
    else
      verdict="fresh"
      FRESH=$((FRESH + 1))
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$status" "$epoch" "$idle_seconds" "$idle_minutes" "$verdict"
done <<EOF
$(in_flight_snapshot "$BACKLOG")
EOF

printf '# summary in_flight=%s fresh=%s stale=%s uninitialized=%s\n' \
  "$TOTAL" "$FRESH" "$STALE" "$UNINIT"
