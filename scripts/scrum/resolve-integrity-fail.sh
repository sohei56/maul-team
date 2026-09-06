#!/usr/bin/env bash
# Resolve an Integrity-stage FAIL and own its durable state transition.
# Usage: resolve-integrity-fail.sh <pbi-id>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/integrity-gates.sh
source "$HERE/lib/integrity-gates.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: resolve-integrity-fail.sh <pbi-id>"
PBI="$1"
assert_pbi_id "$PBI"

STATE=".scrum/pbi/$PBI/state.json"
BACKLOG=".scrum/backlog.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG"

ROUND="$(jq -r '.impl_round // empty' "$STATE")"
case "$ROUND" in ''|*[!0-9]*) fail E_SCHEMA "invalid impl_round in $STATE" ;; esac
KIND="$(jq -r --arg id "$PBI" '.items[]? | select(.id == $id) | .kind // "code"' "$BACKLOG")"
[ -n "$KIND" ] || fail E_INVALID_ARG "pbi not found in backlog: $PBI"
case "$KIND" in code|docs) ;; *) fail E_SCHEMA "unknown PBI kind: $KIND" ;; esac
STATUS="$(jq -r --arg id "$PBI" '.items[]? | select(.id == $id) | .status // empty' "$BACKLOG")"
case "$KIND:$STATUS" in
  code:in_progress_ut_run|docs:in_progress_pbi_review) ;;
  *) fail E_INVALID_ARG \
    "Integrity FAIL resolution requires kind=code/status=in_progress_ut_run or kind=docs/status=in_progress_pbi_review (got: kind=$KIND status=${STATUS:-missing})" ;;
esac

METRICS=".scrum/pbi/$PBI/metrics"
CURRENT="$METRICS/integrity-r$ROUND.json"
PREVIOUS=""
PREVIOUS_ROUND=-1
for candidate in "$METRICS"/integrity-r*.json; do
  [ -e "$candidate" ] || continue
  base="${candidate##*/}"
  candidate_round="${base#integrity-r}"
  candidate_round="${candidate_round%.json}"
  case "$candidate_round" in ''|*[!0-9]*) continue ;; esac
  if [ "$candidate_round" -lt "$ROUND" ] && [ "$candidate_round" -gt "$PREVIOUS_ROUND" ]; then
    # Select only by the filename Round. integrity_gate_outcome validates the
    # selected payload fail-closed; older, unused history is irrelevant.
    PREVIOUS="$candidate"
    PREVIOUS_ROUND="$candidate_round"
  fi
done

OUTCOME="$(integrity_gate_outcome "$KIND" "$ROUND" "$CURRENT" "$PREVIOUS")"
case "$OUTCOME" in
  stagnation|divergence|max_rounds)
    # Canonical invariant: reason is visible before backlog status escalates.
    "$HERE/update-pbi-state.sh" "$PBI" escalation_reason "$OUTCOME"
    "$HERE/update-backlog-status.sh" "$PBI" escalated
    "$HERE/append-pbi-log.sh" "$PBI" pbi_review "$ROUND" gate "escalate → $OUTCOME"
    ;;
  next_round)
    "$HERE/update-pbi-state.sh" "$PBI" impl_status fail
    "$HERE/update-backlog-status.sh" "$PBI" in_progress_impl
    "$HERE/append-pbi-log.sh" "$PBI" pbi_review "$ROUND" gate "integrity FAIL → next round"
    ;;
  *) fail E_SCHEMA "unexpected Integrity gate outcome: $OUTCOME" ;;
esac

printf '%s\n' "$OUTCOME"
