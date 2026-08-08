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
#     [--audit-identity <defect-class>::<pattern>] \
#     [--audit-severity {critical|high|low}]
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
#       A release_decision=no_go can be recorded freely.
#   (d) For kind=defect_triage with decision=reject (exact token), BOTH
#       --audit-identity and --audit-severity are required. A rejection is a
#       persisted suppression that codebase-audit Step 5 must match back to
#       the finding it silenced; without the two keys it is a decision that
#       silently loses its own effect. Only `reject` is gated — the same kind
#       carries the integration-entry fix_now/defer usage, which has no
#       per-finding identity.
#
# The store file is created on first call (initial content
# `{"decisions": []}`) and the parent directory `.scrum/po/` is
# created automatically.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

KIND=""
DECISION=""
RATIONALE=""
SPRINT=""
PBI=""
REQUEST=""
ASSUMPTION="false"
AUDIT_IDENTITY=""
AUDIT_SEVERITY=""
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
    --audit-identity) AUDIT_IDENTITY="$2"; shift 2 ;;
    --audit-severity) AUDIT_SEVERITY="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$KIND" ]      || fail E_INVALID_ARG "--kind required"
[ -n "$DECISION" ]  || fail E_INVALID_ARG "--decision required"
[ -n "$RATIONALE" ] || fail E_INVALID_ARG "--rationale required"

case "$KIND" in
  sprint_goal_approval|pbi_split|escalation_choice|spec_clarification|change_request|demo_acceptance|uat_item|defect_triage|release_decision|git_dirty|backlog_approval|scope_change|sprint_continuation|quality_gate_config) ;;
  *) fail E_INVALID_ARG "bad --kind: $KIND" ;;
esac

if [ -n "$SPRINT" ] && [ "$SPRINT" != "null" ]; then
  assert_sprint_id "$SPRINT" --sprint
fi

if [ -n "$PBI" ] && [ "$PBI" != "null" ]; then
  assert_pbi_id "$PBI" --pbi
fi

PATHF=".scrum/po/decisions.json"
# Resolved before the guards below because the audit-severity check derives its
# allow-list from the schema rather than hardcoding a parallel copy.
SCHEMA="$(resolve_schema_dir)/po-decisions.schema.json"

if [ -n "$AUDIT_IDENTITY" ]; then
  assert_audit_identity "$AUDIT_IDENTITY" --audit-identity
fi
if [ -n "$AUDIT_SEVERITY" ]; then
  SEV_ENUM="$(jq -r '.properties.decisions.items.properties.audit_severity.enum[]
                     | select(. != null)' "$SCHEMA" 2>/dev/null || true)"
  [ -n "$SEV_ENUM" ] || fail E_SCHEMA "cannot read audit_severity enum from $(basename "$SCHEMA")"
  printf '%s\n' "$SEV_ENUM" | grep -Fxq "$AUDIT_SEVERITY" || fail E_INVALID_ARG \
    "bad --audit-severity: $AUDIT_SEVERITY (allowed: $(printf '%s' "$SEV_ENUM" | tr '\n' ' '))"
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

# Guard (d): a defect_triage rejection is a persisted suppression — it must
# name the finding it suppresses and the severity it was rejected at, or
# codebase-audit Step 5 cannot match it back (and cannot lapse it on
# escalation).
if [ "$KIND" = "defect_triage" ] && [ "$DECISION" = "reject" ]; then
  [ -n "$AUDIT_IDENTITY" ] || fail E_INVALID_ARG \
    "defect_triage --decision reject requires --audit-identity (an unmatchable suppression silently loses its own effect)"
  [ -n "$AUDIT_SEVERITY" ] || fail E_INVALID_ARG \
    "defect_triage --decision reject requires --audit-severity (the level it was rejected at; a strictly higher later rating lapses the suppression)"
fi

# Ensure parent dir + store file exist (idempotent init: empty array).
mkdir -p "$(dirname "$PATHF")"
if [ ! -f "$PATHF" ]; then
  # Seed through atomic_create so the first write is schema-validated and lands
  # via temp+mv, matching every subsequent atomic_write mutation.
  atomic_create "$PATHF" "$SCHEMA" '{decisions: []}'
fi

# Compute next id (max dec-NNNN + 1, zero-padded to 4). jq returns 0 when the
# array is empty, so the first record is dec-0001.
NEXT_ID="$(alloc_next_id "$PATHF" '.decisions' 'dec-' 4)"

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
    --arg aid "$AUDIT_IDENTITY" \
    --arg asev "$AUDIT_SEVERITY" \
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
    + {assumption: $assumption}
    + (if $aid == "" then {} else {audit_identity: $aid} end)
    + (if $asev == "" then {} else {audit_severity: $asev} end)'
)"

EXPR=".decisions += [$REC_JSON]"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

# Echo the assigned id on stdout for callers that need to reference the record.
printf '%s\n' "$NEXT_ID"
