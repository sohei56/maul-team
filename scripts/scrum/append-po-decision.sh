#!/usr/bin/env bash
# scripts/scrum/append-po-decision.sh — append one record to .scrum/po/decisions.json.
#
# Usage:
#   append-po-decision.sh \
#     --kind <kind> \
#     --decision <text> \
#     --rationale <text> \
#     [--sprint <sprint-id>] [--pbi <pbi-id>] \
#     [--request <text>] \
#     [--evidence <path>]...   # repeatable
#     [--assumption]            # flag (sets assumption=true)
#
# The PO decisions log is the audit trail for both human-PO and
# autonomous-PO modes. It is append-only — IDs are auto-assigned
# (dec-NNNN, monotonically increasing) and existing records are never
# rewritten. Schema: docs/contracts/scrum-state/po-decisions.schema.json.
#
# Mechanical guards (must hold before any write):
#   (a) --kind must be in the enum (matches schema)
#   (b) For kind ∈ {demo_acceptance, uat_item, release_decision},
#       --evidence must be supplied at least once. Approving without
#       evidence is a process violation.
#   (c) For kind=release_decision with decision=go, .scrum/test-results.json
#       must exist AND .overall_status ∈ {passed, passed_with_skips}.
#       A release_decision=no-go can be recorded freely.
#
# The store file is created on first call (initial content
# `{"decisions": []}`) and the parent directory `.scrum/po/` is
# created automatically.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

KIND=""
DECISION=""
RATIONALE=""
SPRINT=""
PBI=""
REQUEST=""
ASSUMPTION="false"
# Evidence is collected as repeated --evidence flags. We accumulate into a
# jq-array literal piece by piece, then `--argjson` it later. Bash 3.2-safe
# (no arrays-of-arrays / no associative arrays).
EVIDENCE_JSON="[]"

# Append one string to EVIDENCE_JSON using jq so quoting is correct.
_append_evidence() {
  EVIDENCE_JSON="$(jq -c --arg p "$1" '. + [$p]' <<<"$EVIDENCE_JSON")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)       KIND="$2"; shift 2 ;;
    --decision)   DECISION="$2"; shift 2 ;;
    --rationale)  RATIONALE="$2"; shift 2 ;;
    --sprint)     SPRINT="$2"; shift 2 ;;
    --pbi)        PBI="$2"; shift 2 ;;
    --request)    REQUEST="$2"; shift 2 ;;
    --evidence)   _append_evidence "$2"; shift 2 ;;
    --assumption) ASSUMPTION="true"; shift 1 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$KIND" ]      || fail E_INVALID_ARG "--kind required"
[ -n "$DECISION" ]  || fail E_INVALID_ARG "--decision required"
[ -n "$RATIONALE" ] || fail E_INVALID_ARG "--rationale required"

case "$KIND" in
  sprint_goal_approval|pbi_split|escalation_choice|spec_clarification|change_request|demo_acceptance|uat_item|defect_triage|release_decision|git_dirty|backlog_approval|scope_change|sprint_continuation) ;;
  *) fail E_INVALID_ARG "bad --kind: $KIND" ;;
esac

if [ -n "$SPRINT" ] && [ "$SPRINT" != "null" ]; then
  case "$SPRINT" in
    sprint-[0-9]*) ;;
    *) fail E_INVALID_ARG "bad --sprint: $SPRINT" ;;
  esac
fi

if [ -n "$PBI" ] && [ "$PBI" != "null" ]; then
  assert_pbi_id "$PBI" --pbi
fi

# Guard (b): evidence required for approval-kinds. Empty array literal "[]" is
# the only "no evidence" representation here.
EVIDENCE_COUNT="$(jq 'length' <<<"$EVIDENCE_JSON")"
case "$KIND" in
  demo_acceptance|uat_item|release_decision)
    if [ "$EVIDENCE_COUNT" -eq 0 ]; then
      fail E_INVALID_ARG "evidence required for --kind=$KIND (no evidence = no approval)"
    fi
    ;;
esac

# Guard (c): release_decision=go requires green tests.
if [ "$KIND" = "release_decision" ] && [ "$DECISION" = "go" ]; then
  TR=".scrum/test-results.json"
  if [ ! -f "$TR" ]; then
    fail E_INVALID_ARG "release_decision=go requires $TR (not found)"
  fi
  OVERALL="$(jq -r '.overall_status // ""' "$TR" 2>/dev/null || true)"
  case "$OVERALL" in
    passed|passed_with_skips) ;;
    *) fail E_INVALID_ARG "release_decision=go requires test-results.overall_status ∈ {passed, passed_with_skips}, got: ${OVERALL:-<missing>}" ;;
  esac
fi

# Ensure parent dir + store file exist (idempotent init: empty array).
PATHF=".scrum/po/decisions.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/po-decisions.schema.json"
mkdir -p "$(dirname "$PATHF")"
if [ ! -f "$PATHF" ]; then
  printf '%s\n' '{"decisions": []}' > "$PATHF"
fi

# Compute next id (max dec-NNNN + 1, zero-padded to 4). jq returns 0 when the
# array is empty, so the first record is dec-0001.
NEXT_N="$(jq -r '
  (.decisions // [])
  | map(.id | capture("^dec-(?<n>[0-9]+)$").n | tonumber)
  | (max // 0) + 1
' "$PATHF" 2>/dev/null || true)"
case "$NEXT_N" in
  ''|*[!0-9]*) fail E_SCHEMA "could not compute next id from $PATHF" ;;
esac
NEXT_ID="$(printf 'dec-%04d' "$NEXT_N")"

# Build record JSON via jq -n so all free-form text is properly escaped.
REC_JSON="$(
  jq -n \
    --arg id "$NEXT_ID" \
    --arg ts "$(_iso_utc_now)" \
    --arg sprint "$SPRINT" \
    --arg pbi "$PBI" \
    --arg kind "$KIND" \
    --arg request "$REQUEST" \
    --arg decision "$DECISION" \
    --arg rationale "$RATIONALE" \
    --argjson evidence "$EVIDENCE_JSON" \
    --argjson assumption "$ASSUMPTION" \
    '{
      id: $id,
      timestamp: $ts,
      kind: $kind,
      decision: $decision,
      rationale: $rationale
    }
    + (if $sprint == "" or $sprint == "null" then {sprint_id: null} else {sprint_id: $sprint} end)
    + (if $pbi == "" or $pbi == "null" then {pbi_id: null} else {pbi_id: $pbi} end)
    + (if $request == "" then {} else {request: $request} end)
    + (if ($evidence | length) == 0 then {} else {evidence: $evidence} end)
    + {assumption: $assumption}'
)"

EXPR=".decisions += [$REC_JSON]"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

# Echo the assigned id on stdout for callers that need to reference the record.
printf '%s\n' "$NEXT_ID"
