#!/usr/bin/env bats
# skill-frontmatter.bats — Validate YAML frontmatter in all skill SKILL.md files

load '../test_helper/common-setup'

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL_NAMES=(
    sprint-planning
    spawn-teammates
    install-subagents
    pbi-pipeline
    pbi-escalation-handler
    pbi-merge
    cross-review
    sprint-review
    retrospective
    requirements-sprint
    integration-sprint
    backlog-refinement
    change-process
    scaffold-design-spec
    smoke-test
  )
}

# Helper: extract YAML frontmatter (lines between the two --- markers)
# Uses awk for macOS/Linux portability (BSD sed doesn't support this syntax)
extract_frontmatter() {
  local file="$1"
  awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' "$file"
}

@test "all 15 skill directories contain SKILL.md" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    [ -f "$skill_file" ] || {
      echo "Missing SKILL.md for skill: $skill"
      return 1
    }
  done
}

@test "all skills have valid YAML frontmatter" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    extract_frontmatter "$skill_file" | yq '.' > /dev/null 2>&1 || {
      echo "Invalid YAML frontmatter in: $skill_file"
      return 1
    }
  done
}

@test "all skills have name field" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    local name
    name="$(extract_frontmatter "$skill_file" | yq -r '.name')"
    [ -n "$name" ] && [ "$name" != "null" ] || {
      echo "Missing or empty name field in: $skill_file"
      return 1
    }
  done
}

@test "all skills have description field" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    local desc
    desc="$(extract_frontmatter "$skill_file" | yq -r '.description')"
    [ -n "$desc" ] && [ "$desc" != "null" ] || {
      echo "Missing or empty description field in: $skill_file"
      return 1
    }
  done
}

@test "all skills have disable-model-invocation set to false" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    local value
    value="$(extract_frontmatter "$skill_file" | yq '.["disable-model-invocation"]')"
    [ "$value" = "false" ] || {
      echo "disable-model-invocation is not false in: $skill_file (got: $value)"
      return 1
    }
  done
}

@test "all skills have Inputs section" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    grep -q '^## Inputs' "$skill_file" || {
      echo "Missing '## Inputs' section in: $skill_file"
      return 1
    }
  done
}

@test "all skills have Outputs section" {
  for skill in "${SKILL_NAMES[@]}"; do
    local skill_file="${PROJECT_ROOT}/skills/${skill}/SKILL.md"
    grep -q '^## Outputs' "$skill_file" || {
      echo "Missing '## Outputs' section in: $skill_file"
      return 1
    }
  done
}
