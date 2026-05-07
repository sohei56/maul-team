#!/usr/bin/env bash
# scripts/scrum/append-pbi-log.sh — append one line to .scrum/pbi/<pbi-id>/pipeline.log.
# Usage: append-pbi-log.sh <pbi-id> <stage> <round> <event> <detail>
# Format: <ISO8601-UTC>\t<stage>\t<round>\t<event>\t<detail>
#
# `<stage>` is a coarse pipeline-stage digest, NOT the 12-value backlog
# status enum. The set is fixed (init|design|pbi_review|ut_run|complete|
# escalated) so the log stays human-scannable; status SSOT lives at
# `backlog.json.items[].status` and is written via update-backlog-status.sh.
# Note: short writes (<4KB total) are line-atomic per POSIX; longer details may interleave.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 5 ] || fail E_INVALID_ARG "usage: append-pbi-log.sh <pbi-id> <stage> <round> <event> <detail>"
PBI="$1"; PHASE="$2"; ROUND="$3"; EVENT="$4"; DETAIL="$5"

case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac
case "$PHASE" in
  init|design|pbi_review|ut_run|complete|escalated) ;;
  *) fail E_INVALID_ARG "bad stage: $PHASE (allowed: init|design|pbi_review|ut_run|complete|escalated)" ;;
esac
case "$ROUND" in
  ''|*[!0-9]*) fail E_INVALID_ARG "round must be non-negative integer (got: $ROUND)" ;;
esac

LOGF=".scrum/pbi/$PBI/pipeline.log"
mkdir -p "$(dirname "$LOGF")"
ts="$(_iso_utc_now)"
printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$PHASE" "$ROUND" "$EVENT" "$DETAIL" >> "$LOGF"
