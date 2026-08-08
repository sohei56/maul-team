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
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/init-backlog.sh" --product-goal "roundtrip" >/dev/null
  IDENTITY="notify-order::send-before-write"
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
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "[codebase-audit:sprint-001:F1:High] notify order inverted" \
    --audit-identity "$IDENTITY" \
    --description "Codebase-audit F1 (High). Occurrences: a.py:10 — run." \
    --ac "the sweep pattern finds no remaining instance" \
    --kind code
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

@test "roundtrip: a non-audit PBI carrying the same identity never matches" {
  # The title filter matters: without it the EXISTING lookup could resolve to
  # an unrelated PBI and the audit would report the wrong tracking id.
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/add-backlog-item.sh" \
    --title "ordinary feature PBI" --kind code >/dev/null
  LAST="$(jq -r '.items[-1].id' .scrum/backlog.json)"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/set-backlog-item-field.sh" "$LAST" audit_identity "$IDENTITY"
  [ "$(open_match)" -eq 0 ]
}
