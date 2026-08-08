#!/usr/bin/env bats
# tests/lint/audit-spec-adjudication.bats — a frozen spec must never be able to
# silence a real defect for free.
#
# Two mechanisms guard that, and both are prose:
#   1. Axis A class 4 lets the audit report the CLAUSE, not just the code.
#   2. `spec-exempted:` blocks leave a trace when a clause suppressed a
#      finding, so the judgement is not re-made from scratch every Sprint.
# Prose drifts silently; these tests pin the load-bearing parts.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AUDIT_SKILL="${PROJECT_ROOT}/skills/codebase-audit/SKILL.md"
  AXES="${PROJECT_ROOT}/skills/codebase-audit/references/axes.md"
  CROSS_REVIEW="${PROJECT_ROOT}/skills/cross-review/SKILL.md"
}

@test "Axis A declares four failure classes" {
  local axis_a
  axis_a="$(awk '/^## Axis A —/{f=1} /^## Axis B —/{f=0} f' "$AXES")"
  printf '%s' "$axis_a" | grep -q 'Hunt four failure classes' || {
    echo "Axis A no longer announces four failure classes" >&2
    return 1
  }
  printf '%s' "$axis_a" | grep -q 'Spec-sanctions-a-defect' || {
    echo "Axis A lost the spec-sanctions-a-defect class" >&2
    return 1
  }
}

@test "class 4 demands sibling-implementation evidence, not the spec's authority" {
  # The measured failure mode: auditors accept a clause as proof the behavior
  # is correct. The only judgement that reliably escaped it was contrasting a
  # sibling implementation in the same repo.
  local axis_a
  axis_a="$(awk '/^## Axis A —/{f=1} /^## Axis B —/{f=0} f' "$AXES")"
  printf '%s' "$axis_a" | grep -q 'sibling implementation' || {
    echo "class 4 no longer requires a sibling-implementation contrast" >&2
    return 1
  }
  printf '%s' "$axis_a" | grep -q "provenance" || {
    echo "class 4 no longer requires the clause's provenance as evidence" >&2
    return 1
  }
}

@test "divergence does not presume the code is the wrong side" {
  local axis_a
  axis_a="$(awk '/^## Axis A —/{f=1} /^## Axis B —/{f=0} f' "$AXES")"
  # Wrap-tolerant: the sentence spans a line break in the source.
  printf '%s' "$axis_a" | tr '\n' ' ' | tr -s ' ' \
    | grep -q 'Do not assume the code is the wrong side' || {
    echo "class 1 no longer tells the auditor to name which side it believes" >&2
    return 1
  }
}

@test "axes require a spec-exempted record when a clause suppresses a finding" {
  grep -q 'Record what a spec exemption silenced' "$AXES" || {
    echo "axes.md no longer requires recording spec-driven suppressions" >&2
    return 1
  }
}

@test "the audit report carries a spec-exempted section" {
  grep -q 'Spec-exempted observations' "$AUDIT_SKILL" || {
    echo "codebase-audit no longer collects spec-exempted observations" >&2
    return 1
  }
  grep -q 'spec-exempted' "$CROSS_REVIEW" || {
    echo "cross-review exit criteria no longer mention spec-exempted observations" >&2
    return 1
  }
}
