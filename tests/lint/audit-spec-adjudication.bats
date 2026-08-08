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

@test "Step 5 consults the PO decision log for a defect_triage suppression" {
  grep -q 'select(.kind == "defect_triage")' "$AUDIT_SKILL" || {
    echo "Step 5 no longer looks up a defect_triage suppression" >&2
    return 1
  }
  grep -q 'select(.decision == "reject")' "$AUDIT_SKILL" || {
    echo "Step 5 no longer restricts the suppression to a reject verdict" >&2
    return 1
  }
  # `last //` is what makes a later verdict supersede an earlier reject; drop
  # it and the reject becomes permanent with no un-reject verb anywhere.
  grep -q 'last // empty' "$AUDIT_SKILL" || {
    echo "Step 5 lost the last-verdict-wins supersession" >&2
    return 1
  }
}

@test "the audit report carries a suppressed-by-PO-decision section" {
  # A suppression with no trace in the report is indistinguishable from a
  # finding nobody noticed — which is the whole failure this section closes.
  grep -q 'Suppressed by PO decision' "$AUDIT_SKILL" || {
    echo "the audit report structure lost the suppression section" >&2
    return 1
  }
}

@test "the axes must not treat a defect_triage record as grounds to skip" {
  # The axes already read decisions.json for classes 3/4, so an auditor will
  # over-generalize any decision into \"already decided, skip it\" unless told
  # otherwise — and the escalation re-open needs a fresh rating every Sprint.
  printf '%s' "$(tr '\n' ' ' < "$AXES" | tr -s ' ')" \
    | grep -q 'A `defect_triage` record is not grounds to skip anything' || {
    echo "axes.md no longer forbids skipping a finding on a defect_triage record" >&2
    return 1
  }
}

@test "Step 4a names the wrapper for the human-PO recording duty" {
  # The first instruction in this repo telling the SM to write a PO decision
  # record on the human's behalf. Unpinned, it reads as redundant and is swept.
  local step4a
  step4a="$(awk '/^\*\*4a —/{f=1} /^\*\*4b —/{f=0} f' "$AUDIT_SKILL")"
  printf '%s' "$step4a" | grep -q 'append-po-decision.sh' || {
    echo "Step 4a no longer names append-po-decision.sh" >&2
    return 1
  }
  printf '%s' "$step4a" | tr '\n' ' ' | tr -s ' ' \
    | grep -q "on the human's behalf" || {
    echo "Step 4a no longer states the human-PO proxy recording duty" >&2
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
