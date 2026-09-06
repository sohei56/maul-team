#!/usr/bin/env bats
# tests/lint/demo-plan-negative-case.bats — Issue #97: a guard-type
# deliverable's demo_plan must carry a `negative:` (guard FAILs on the injected
# defect) and a `positive:` (guard PASSes once removed) step, and the ceremonies
# that execute the plan must run both. Prompt obligation, not a machine gate —
# so pin the wording that carries it.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  REFINE_SKILL="$PROJECT_ROOT/skills/backlog-refinement/SKILL.md"
  REVIEW_SKILL="$PROJECT_ROOT/skills/sprint-review/SKILL.md"
  PO_SKILL="$PROJECT_ROOT/skills/po-acceptance/SKILL.md"
}

# Both labelled markers must appear in the file (the pair is the obligation;
# either marker alone is not the rule).
assert_negative_case_markers() {
  run grep -F -- '`negative:`' "$1"
  [ "$status" -eq 0 ]
  run grep -F -- '`positive:`' "$1"
  [ "$status" -eq 0 ]
}

@test "backlog-refinement defines the guard negative-case rule" {
  assert_negative_case_markers "$REFINE_SKILL"
  run grep -F 'Guard-type deliverables MUST demo the failing direction' "$REFINE_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'cannot be made to fail on demand is not accepted as' "$REFINE_SKILL"
  [ "$status" -eq 0 ]
  # Extra Check 6 flags a missing negative case during the AC audit.
  run grep -F 'Extra Check 6 — demo_plan locality + guard negative case' "$REFINE_SKILL"
  [ "$status" -eq 0 ]
}

@test "backlog-refinement exit criteria list the negative case" {
  run grep -F 'labelled steps — `negative:` (guard FAILs on the injected defect)' "$REFINE_SKILL"
  [ "$status" -eq 0 ]
}

@test "sprint-review requires both demo directions to be executed" {
  assert_negative_case_markers "$REVIEW_SKILL"
  run grep -F 'passing direction is "not demonstrated"' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
  run grep -F '../backlog-refinement/SKILL.md` Step 3.c2' "$REVIEW_SKILL"
  [ "$status" -eq 0 ]
}

@test "po-acceptance fails a guard shown only passing" {
  assert_negative_case_markers "$PO_SKILL"
  run grep -F 'guard shown only passing is `fail`, not `pass`' "$PO_SKILL"
  [ "$status" -eq 0 ]
  run grep -F '../backlog-refinement/SKILL.md` Step 3.c2' "$PO_SKILL"
  [ "$status" -eq 0 ]
}

@test "the marker assertion is not vacuous (negative fixture)" {
  fixture="$BATS_TEST_TMPDIR/no-markers.md"
  printf 'demo_plan: run the app and confirm it works.\n' > "$fixture"
  run grep -F -- '`negative:`' "$fixture"
  [ "$status" -ne 0 ]
  run grep -F -- '`positive:`' "$fixture"
  [ "$status" -ne 0 ]
  # A file carrying only one of the pair must still not satisfy the contract.
  printf 'a `positive:` step alone.\n' > "$fixture"
  run grep -F -- '`negative:`' "$fixture"
  [ "$status" -ne 0 ]
}

@test "update-backlog-status warns (never refuses) on a guard-shaped plan" {
  wrapper="$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh"
  run grep -F 'GUARD_DEMO_KEYWORDS=' "$wrapper"
  [ "$status" -eq 0 ]
  run grep -F 'Not blocking.' "$wrapper"
  [ "$status" -eq 0 ]
}
