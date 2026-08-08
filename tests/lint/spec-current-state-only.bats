#!/usr/bin/env bats
# tests/lint/spec-current-state-only.bats — a spec body states the present.
#
# One rule (catalog Governance Rule 8), one Sprint-end detector (Axis A
# class 5), one in-diff detector (docs-consistency-reviewer criterion 7), and
# four writer-local pointers back to the rule. Every part is prose, and the
# failure modes are asymmetric: losing a carve-out turns every legitimate
# `revision_history` append into a violation, while losing the "not history"
# escape turns every migration spec into a finding. Both are pinned here.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CATALOG="${PROJECT_ROOT}/docs/design/catalog.md"
  AXES="${PROJECT_ROOT}/skills/codebase-audit/references/axes.md"
  REVIEWER="${PROJECT_ROOT}/agents/docs-consistency-reviewer.md"
}

rule_8_block() {
  awk '/^8\. \*\*Current state only/{f=1} /^## How to read/{f=0} f' "$CATALOG"
}

@test "catalog carries Governance Rule 8 as a content rule" {
  grep -qF '8. **Current state only.**' "$CATALOG" || {
    echo "docs/design/catalog.md lost Governance Rule 8" >&2
    return 1
  }
}

@test "Rule 8 names both carve-outs" {
  # Without them the rule self-destructs: `revision_history` is mandatory
  # (Rule 6) and a D-001 ADR's whole subject is a past decision.
  local block
  block="$(rule_8_block)"
  printf '%s' "$block" | grep -q 'revision_history' || {
    echo "Rule 8 no longer exempts frontmatter revision_history" >&2
    return 1
  }
  printf '%s' "$block" | grep -q 'D-001' || {
    echo "Rule 8 no longer exempts D-001 Architecture Decision Records" >&2
    return 1
  }
}

@test "Rule 8 keeps the \"not history\" escape" {
  # S-060 Migration / Upgrade is an enabled catalog type whose body
  # legitimately spans versions. Drop this sentence and the audit files a
  # false positive against every migration spec, and auditors learn to
  # ignore class 5.
  local block
  block="$(rule_8_block)"
  printf '%s' "$block" | grep -q 'S-060' || {
    echo "Rule 8 lost the S-060 migration-range escape" >&2
    return 1
  }
  printf '%s' "$block" | grep -q 'backward-compat' || {
    echo "Rule 8 lost the live backward-compat escape" >&2
    return 1
  }
}

@test "Axis A class 5 needs no code evidence and batches on one identity" {
  local axis_a
  axis_a="$(awk '/^## Axis A —/{f=1} /^## Axis B —/{f=0} f' "$AXES")"
  printf '%s' "$axis_a" | grep -q 'No code evidence is required' || {
    echo "class 5 no longer states that no code evidence is required" >&2
    return 1
  }
  # Identity drift is what files duplicate PBIs Sprint after Sprint — the
  # exact failure `audit_identity` was added to fix.
  printf '%s' "$axis_a" | grep -q 'spec-history::body-changelog' || {
    echo "class 5 lost the repo-wide batched identity" >&2
    return 1
  }
}

@test "the in-diff reviewer criterion is wired end to end" {
  # An enum entry with no criterion text is emitted by nobody, and criterion
  # text with no enum entry has no signature to report under.
  grep -q 'spec_history_in_body' "$REVIEWER" || {
    echo "docs-consistency-reviewer lost the spec_history_in_body key" >&2
    return 1
  }
  grep -q '^7\. \*\*Spec history in the body' "$REVIEWER" || {
    echo "docs-consistency-reviewer lost criterion 7" >&2
    return 1
  }
  # The criteria split must be named, not positional: "the last two" silently
  # mis-buckets whichever key is appended next.
  ! grep -q 'The last two apply to docs PBIs' "$REVIEWER" || {
    echo "docs-consistency-reviewer still indexes its criteria positionally" >&2
    return 1
  }
}

@test "every writer of a spec body points at Rule 8" {
  # Pointer rot is the standard failure mode for one-fact-one-file.
  local writers=(
    "agents/pbi-designer.md"
    "agents/requirements-analyst.md"
    "skills/scaffold-design-spec/SKILL.md"
    "skills/change-process/SKILL.md"
  )
  local w flat
  for w in "${writers[@]}"; do
    # Wrap-tolerant: the pointer spans a line break in some of these files.
    flat="$(tr '\n' ' ' < "${PROJECT_ROOT}/${w}" | tr -s ' ')"
    printf '%s' "$flat" | grep -q 'Governance Rule 8' || {
      echo "${w} no longer points at catalog Governance Rule 8" >&2
      return 1
    }
  done
}
