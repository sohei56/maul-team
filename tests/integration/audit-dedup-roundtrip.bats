#!/usr/bin/env bats
# tests/integration/audit-dedup-roundtrip.bats — the cross-Sprint dedup loop,
# exercised end to end against the real wrapper and the real jq from
# skills/codebase-audit/SKILL.md Step 5.
#
# The unit tests cover the field; this covers the decision the SM actually
# makes with it: file, skip, or file-as-REGRESSION. It is the check that would
# have caught the original bug, where a description substring match let a
# one-character difference file a duplicate.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/audit-dedup.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/audit-dedup.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  for s in backlog po-decisions; do
    cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/
  done
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/init-backlog.sh" --product-goal "roundtrip" >/dev/null
  IDENTITY="notify-order::send-before-write"
  DOCS_IDENTITY="docs-drift::stale-references"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# The dedup queries, kept in the same shape as SKILL.md Step 5.
open_match() {
  jq --arg aid "$IDENTITY" '
    [.items[]
     | select(.title | startswith("[codebase-audit:"))
     | select(.audit_identity == $aid)
     | select(.status != "done" and .status != "cancelled")] | length' .scrum/backlog.json
}
done_match() {
  jq --arg aid "$IDENTITY" '
    [.items[]
     | select(.title | startswith("[codebase-audit:"))
     | select(.audit_identity == $aid)
     | select(.status == "done")] | length' .scrum/backlog.json
}

_file_audit_pbi() {
  local sev="${1:-high}" label="${2:-High}"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F1:${label}] notify order inverted" \
    --audit-identity "$IDENTITY" \
    --audit-severity "$sev" \
    --description "Codebase-audit F1 (${label}). Occurrences: a.py:10 — run." \
    --ac "the sweep pattern finds no remaining instance" \
    --kind code
}

# The Step 5 suppression lookup, kept in the same shape as SKILL.md: the LAST
# defect_triage verdict for the identity wins, and the fixed DOCS identity is
# never consulted.
suppressed() {
  local identity="$1"
  [ "$identity" = "$DOCS_IDENTITY" ] && return 0
  [ -f .scrum/po/decisions.json ] || return 0
  jq -r --arg aid "$identity" '
    [.decisions[] | select(.kind == "defect_triage") | select(.audit_identity == $aid)]
    | last // empty | select(.decision == "reject") | "\(.id) \(.audit_severity)"' \
    .scrum/po/decisions.json
}

# The Step 1b block predicate: everything that is not `low` blocks.
open_blocking() {
  jq '[.items[]
    | select(.title | startswith("[codebase-audit:"))
    | select((.audit_severity // "high") != "low")
    | select(.status != "done" and .status != "cancelled")] | length' .scrum/backlog.json
}

_triage() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-po-decision.sh" \
    --kind defect_triage --decision "$1" --rationale "roundtrip" \
    --audit-identity "$2" --audit-severity "$3"
}

@test "roundtrip: an open audit PBI suppresses a re-filing of the same class" {
  [ "$(open_match)" -eq 0 ]
  PBI="$(_file_audit_pbi)"
  [ "$(open_match)" -eq 1 ]
  [ "$(done_match)" -eq 0 ]

  # Second Sprint re-detects the class → open match → skip, and the SM can
  # name the PBI already tracking it.
  EXISTING="$(jq -r --arg aid "$IDENTITY" '
    .items[]
    | select(.title | startswith("[codebase-audit:"))
    | select(.audit_identity == $aid)
    | select(.status != "done" and .status != "cancelled") | .id' .scrum/backlog.json | head -1)"
  [ "$EXISTING" = "$PBI" ]
}

@test "roundtrip: cancelled does not suppress re-detection (symmetry with Step 1b)" {
  PBI="$(_file_audit_pbi)"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" "$PBI" cancelled
  # Neither open nor done → the next audit files it again, as it should: the PO
  # descoped one PBI, not the defect class forever.
  [ "$(open_match)" -eq 0 ]
  [ "$(done_match)" -eq 0 ]
}

@test "roundtrip: done match with no open match is the REGRESSION path" {
  PBI="$(_file_audit_pbi)"
  # kind=code cannot reach `refined` without a demo_plan (the refinement gate).
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" \
    "$PBI" demo_plan 'run the sweep pattern; observe zero remaining instances'
  for s in refined in_progress_impl in_progress_pbi_review in_progress_merge awaiting_cross_review cross_review done; do
    env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh" "$PBI" "$s"
  done
  [ "$(open_match)" -eq 0 ]
  [ "$(done_match)" -eq 1 ]
}

@test "roundtrip: a PO reject suppresses the finding at the same severity" {
  DEC="$(_triage reject "$IDENTITY" low)"
  run suppressed "$IDENTITY"
  [ "$output" = "$DEC low" ]
  # Nothing was filed, so the class is not tracked by any PBI either.
  [ "$(open_match)" -eq 0 ]
}

@test "roundtrip: a strictly higher rating lapses the suppression" {
  _triage reject "$IDENTITY" low >/dev/null
  # The record still exists — the lapse is the SM's severity comparison
  # (low < high < critical), not a mutation of the log.
  run suppressed "$IDENTITY"
  [[ "$output" == *" low" ]]
  RECORDED="${output##* }"
  [ "$RECORDED" = "low" ]
  # This audit rates the same class critical → strictly higher → re-raise.
  [ "$RECORDED" != "critical" ]
}

@test "roundtrip: the latest verdict wins (supersession, no un-reject verb)" {
  _triage reject "$IDENTITY" low >/dev/null
  _triage next_sprint "$IDENTITY" high >/dev/null
  run suppressed "$IDENTITY"
  [ -z "$output" ]
}

@test "roundtrip: the DOCS identity is never suppressed" {
  # One reject on the fixed batch identity would blind the documentation-drift
  # channel permanently, so Step 5 skips the lookup for it entirely.
  _triage reject "$DOCS_IDENTITY" low >/dev/null
  run suppressed "$DOCS_IDENTITY"
  [ -z "$output" ]
}

@test "roundtrip: an open PBI is re-ranked when a later audit rates it higher" {
  PBI="$(_file_audit_pbi low Low)"
  # A `low` PBI is outside the block set...
  [ "$(open_blocking)" -eq 0 ]
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" \
    "$PBI" audit_severity critical
  # ...and the re-rank puts it in, which is the whole point: without it the
  # block-check keeps consulting a stale rating.
  [ "$(open_blocking)" -eq 1 ]
  # The title deliberately still says Low — the field is canonical.
  run jq -r --arg id "$PBI" '.items[] | select(.id == $id) | .title' .scrum/backlog.json
  [[ "$output" == *":F1:Low]"* ]]
}

@test "roundtrip: a legacy audit PBI with no severity blocks (fail-safe)" {
  PBI="$(_file_audit_pbi high High)"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" \
    "$PBI" audit_severity null
  [ "$(open_blocking)" -eq 1 ]
}

@test "roundtrip: a non-audit PBI carrying audit_severity is never counted" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature PBI" --kind code --audit-severity critical >/dev/null
  # The title filter runs first in every block and dedup query, so a stray
  # field on a non-audit item is inert.
  [ "$(open_blocking)" -eq 0 ]
}

@test "roundtrip: a non-audit PBI carrying the same identity never matches" {
  # The title filter matters: without it the EXISTING lookup could resolve to
  # an unrelated PBI and the audit would report the wrong tracking id.
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature PBI" --kind code >/dev/null
  LAST="$(jq -r '.items[-1].id' .scrum/backlog.json)"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" "$LAST" audit_identity "$IDENTITY"
  [ "$(open_match)" -eq 0 ]
}
