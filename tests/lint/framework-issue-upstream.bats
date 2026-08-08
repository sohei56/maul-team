#!/usr/bin/env bats
# tests/lint/framework-issue-upstream.bats — the upstream leg publishes a
# target project's words to a public repo, so its two guards are prose and
# prose drifts silently:
#   1. Retrospective Step 4b must never post without an in-session human yes.
#   2. It must never route that permission through the PO seat — an agent PO
#      has no authority to consent to publication.
# The second is the one a future "make it mode-symmetric" edit would break, so
# it is asserted negatively.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RETRO="${PROJECT_ROOT}/skills/retrospective/SKILL.md"
  WRAPPER="${PROJECT_ROOT}/scripts/scrum/draft-framework-issue.sh"
  PRIVACY_RULE="${PROJECT_ROOT}/.claude/rules/no-private-project-references.md"
}

# step_4b — the Step 4b block only (up to but excluding Step 5).
step_4b() {
  awk '/^4b\. /{f=1} /^5\. /{f=0} f' "$RETRO"
}

@test "retrospective has a Step 4b that drafts through the wrapper" {
  local step; step="$(step_4b)"
  [ -n "$step" ] || {
    echo "skills/retrospective/SKILL.md has no Step 4b block" >&2
    return 1
  }
  printf '%s' "$step" | grep -q 'draft-framework-issue\.sh' || {
    echo "Step 4b no longer names draft-framework-issue.sh — hand-written" \
         "issue prose has no sanitizer" >&2
    return 1
  }
}

@test "Step 4b forbids posting without an explicit in-session permission" {
  local step; step="$(step_4b | tr '\n' ' ' | tr -s ' ')"
  printf '%s' "$step" | grep -q 'Never post without an explicit' || {
    echo "Step 4b lost the no-post-without-permission rule" >&2
    return 1
  }
  printf '%s' "$step" | grep -q 'full draft body inline in chat' || {
    echo "Step 4b no longer requires rendering the body inline — approving a" \
         "path is not informed consent" >&2
    return 1
  }
}

@test "Step 4b never routes publication through the PO seat" {
  # Public posting is outward-facing and irreversible: the same class the PO
  # is barred from (agents/product-owner.md § human-only). A PO_DECISION_REQUEST
  # here would let an unattended run publish a target project's words.
  local step; step="$(step_4b)"
  if printf '%s' "$step" | grep -q 'PO_DECISION_REQUEST'; then
    echo "Step 4b routes an upstream post through PO_DECISION_REQUEST —" \
         "the PO seat cannot consent to publication" >&2
    return 1
  fi
  printf '%s' "$step" | tr '\n' ' ' | tr -s ' ' | grep -qi 'do not ask the PO' || {
    echo "Step 4b's agent-mode branch no longer says the PO is not asked" >&2
    return 1
  }
}

@test "the wrapper declares the sanitizer's non-goal" {
  # Overselling the sanitizer is how the human gate gets rubber-stamped.
  grep -q 'not a sandbox' "$WRAPPER" || {
    echo "draft-framework-issue.sh dropped its non-goal statement" >&2
    return 1
  }
  grep -q 'no --force' "$WRAPPER" || {
    echo "draft-framework-issue.sh no longer states that there is no bypass" >&2
    return 1
  }
}

@test "the privacy rule and its deployed enforcer stay cross-linked" {
  # This repo's rule is not deployed to targets; the wrapper is the only copy
  # of it a target ever sees. Neither may be edited without the other.
  [ -f "$PRIVACY_RULE" ]
  grep -q 'draft-framework-issue\.sh' "$PRIVACY_RULE" || {
    echo "no-private-project-references.md no longer points at its deployed" \
         "counterpart" >&2
    return 1
  }
  grep -q 'no-private-project-references' "$WRAPPER" \
    || grep -q 'skills/retrospective/SKILL.md' "$WRAPPER" || {
    echo "the wrapper no longer points back at the rule or the review gate" >&2
    return 1
  }
}
