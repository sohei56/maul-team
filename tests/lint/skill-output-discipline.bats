#!/usr/bin/env bats
# skill-output-discipline.bats — Every deployed SKILL.md must carry the
# canonical Output-discipline pointer exactly once, inside its `## Outputs`
# section. The rule itself lives in rules/scrum-context.md § Output
# discipline; skills point at it and never restate it.

load '../test_helper/common-setup'

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # Deployed Scrum-ceremony skills (skills/) — mirrors skill-frontmatter.bats.
  SKILL_NAMES=(
    sprint-planning
    spawn-teammates
    install-subagents
    pbi-pipeline
    pbi-escalation-handler
    pbi-merge
    cross-review
    codebase-audit
    sprint-review
    retrospective
    requirement-definition
    integration-tests
    uat-release
    backlog-refinement
    change-process
    scaffold-design-spec
    smoke-test
    po-acceptance
    create-brief
  )

  # The canonical pointer, as one logical sentence. Skills wrap it across
  # two physical lines to respect the 80-char prose width, so every check
  # below compares whitespace-normalized text.
  SKILL_POINTER='**Output discipline.** Follow `../../rules/scrum-context.md` § Output discipline — lead with the outcome, no preamble, no closing recap.'

  # The 12 agents that carry the same pointer (agents/ is not modified by
  # this suite; this only guards against silent removal).
  AGENT_NAMES=(
    developer
    product-owner
    requirements-analyst
    pbi-designer
    pbi-implementer
    pbi-ut-author
    codex-design-reviewer
    requirement-conformance-reviewer
    functional-quality-reviewer
    security-reviewer
    maintainability-reviewer
    docs-consistency-reviewer
  )
  AGENT_POINTER='`../rules/scrum-context.md` § Output discipline'
}

# Collapse newlines and runs of whitespace so a wrapped pointer matches.
normalize() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

# Count non-overlapping occurrences of a literal needle in a haystack.
# Bash 3.2 compatible (no grep -o, which would need the needle escaped).
count_occurrences() {
  local haystack="$1" needle="$2" n=0 rest
  rest="$haystack"
  while [ "${rest#*"$needle"}" != "$rest" ]; do
    rest="${rest#*"$needle"}"
    n=$((n + 1))
  done
  echo "$n"
}

# Extract the `## Outputs` section body (up to the next `## ` heading).
extract_outputs_section() {
  awk '/^## Outputs/{p=1;next} p&&/^## /{exit} p{print}' "$1"
}

@test "every skill carries the Output discipline pointer exactly once" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    local count
    count="$(count_occurrences "$(normalize "$skill_file")" "$SKILL_POINTER")"
    [ "$count" = "1" ] || {
      echo "Expected exactly 1 Output-discipline pointer in ${skill_file}, got ${count}"
      echo "Expected line pair:"
      echo '**Output discipline.** Follow `../../rules/scrum-context.md` § Output'
      echo 'discipline — lead with the outcome, no preamble, no closing recap.'
      return 1
    }
  done
}

@test "the pointer lives in the skill's Outputs section" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    local section count
    section="$(extract_outputs_section "$skill_file" | tr '\n' ' ' | tr -s ' ')"
    count="$(count_occurrences "$section" "$SKILL_POINTER")"
    [ "$count" = "1" ] || {
      echo "Output-discipline pointer not found in the '## Outputs' section of: $skill_file"
      return 1
    }
  done
}

@test "no skill restates the canonical rule instead of pointing at it" {
  # The canonical wording belongs in rules/scrum-context.md only.
  local hits
  hits="$(grep -rlF 'Default to the shortest output' "${PROJECT_ROOT}/skills" || true)"
  [ -z "$hits" ] || {
    echo "Skills must point at the canonical rule, not restate it. Offenders:"
    echo "$hits"
    return 1
  }
}

@test "negative fixture: a skill without the pointer fails the check" {
  setup_temp_dir
  local fixture="${TEMP_DIR}/SKILL.md"
  grep -vF 'Output discipline.' "${PROJECT_ROOT}/skills/smoke-test/SKILL.md" \
    | grep -vF 'no preamble, no closing recap' > "$fixture"

  local count
  count="$(count_occurrences "$(normalize "$fixture")" "$SKILL_POINTER")"
  [ "$count" = "0" ] || {
    echo "Negative fixture still matched the pointer (count=${count})"
    teardown_temp_dir
    return 1
  }
  teardown_temp_dir
}

@test "negative fixture: a duplicated pointer fails the exactly-once check" {
  setup_temp_dir
  local fixture="${TEMP_DIR}/SKILL.md"
  cat "${PROJECT_ROOT}/skills/smoke-test/SKILL.md" \
      "${PROJECT_ROOT}/skills/smoke-test/SKILL.md" > "$fixture"

  local count
  count="$(count_occurrences "$(normalize "$fixture")" "$SKILL_POINTER")"
  [ "$count" = "2" ] || {
    echo "Expected the duplicated fixture to yield 2 pointers, got ${count}"
    teardown_temp_dir
    return 1
  }
  teardown_temp_dir
}

@test "the 12 agents still carry their Output discipline pointer" {
  for agent in "${AGENT_NAMES[@]}"; do
    local agent_file="${PROJECT_ROOT}/agents/${agent}.md"
    [ -f "$agent_file" ] || {
      echo "Missing agent file: $agent_file"
      return 1
    }
    local count
    count="$(count_occurrences "$(normalize "$agent_file")" "$AGENT_POINTER")"
    [ "$count" -ge 1 ] || {
      echo "Missing Output-discipline pointer in: $agent_file"
      return 1
    }
  done
}
