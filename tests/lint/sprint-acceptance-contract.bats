#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PO_AGENT="$PROJECT_ROOT/agents/product-owner.md"
  REVIEW_SKILL="$PROJECT_ROOT/skills/sprint-review/SKILL.md"
}

@test "PO protocol exposes aggregate Sprint acceptance with canonical verdicts" {
  run grep -F 'sprint_acceptance | uat_item' "$PO_AGENT"
  [ "$status" -eq 0 ]
  run grep -F '`kind=sprint_acceptance` uses exactly' "$PO_AGENT"
  [ "$status" -eq 0 ]
  run grep -F '`approve | reject`; `accept` is not a legal alias.' "$PO_AGENT"
  [ "$status" -eq 0 ]
}

@test "Sprint Review obtains and persists aggregate acceptance from per-PBI evidence" {
  run grep -F 'kind=sprint_acceptance options=[approve,reject]' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F '.scrum/scripts/append-po-decision.sh' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F -- '--evidence "<per-PBI transcript-or-report-path>"' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'PBI `done` semantics are unchanged' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
}

@test "Sprint Review exit criteria accept a grounded terminal verdict" {
  run grep -F '.scrum/po/decisions.json → one Sprint-scoped `kind=sprint_acceptance`' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F '`decision=approve|reject` and at least one non-blank per-PBI' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'the latest controls.' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
}

@test "Sprint rejection is terminal, remediated, and separate from release" {
  run grep -F 'Increment may then proceed to Retrospective' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'PBI with its source verdict/evidence' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'never substitutes for `kind=release_decision`' "$PO_AGENT"
  [ "$status" -eq 0 ]
}
