#!/usr/bin/env bats
# agent-frontmatter.bats — Validate YAML frontmatter in agent definition files

load '../test_helper/common-setup'

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# Helper: extract YAML frontmatter (lines between the two --- markers)
# Uses awk for macOS/Linux portability (BSD sed doesn't support this syntax)
extract_frontmatter() {
  local file="$1"
  awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' "$file"
}

# ---------------------------------------------------------------------------
# scrum-master.md
# ---------------------------------------------------------------------------

@test "scrum-master.md has valid YAML frontmatter" {
  run bash -c "extract_frontmatter() { awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' \"\$1\"; }; extract_frontmatter '${PROJECT_ROOT}/agents/scrum-master.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "scrum-master.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq -r '.name'"
  assert_success
  assert_output "scrum-master"
}

@test "scrum-master.md has description field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq -r '.description'"
  assert_success
  refute_output ""
}

@test "scrum-master.md has skills field with 12 entries" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq '.skills | length'"
  assert_success
  assert_output "12"
}

@test "scrum-master.md mentions Delegate mode" {
  run grep -iE 'Delegate|delegate mode' "${PROJECT_ROOT}/agents/scrum-master.md"
  assert_success
}

@test "scrum-master.md has effort field set to high" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq -r '.effort'"
  assert_success
  assert_output "high"
}

@test "scrum-master.md has maxTurns field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq -r '.maxTurns'"
  assert_success
  assert_output "300"
}

@test "scrum-master.md has disallowedTools including Write and Edit" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq '.disallowedTools | length'"
  assert_success
  assert_output "2"
}

@test "scrum-master.md has keep-coding-instructions set to true" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq -r '.\"keep-coding-instructions\"'"
  assert_success
  assert_output "true"
}

# ---------------------------------------------------------------------------
# developer.md
# ---------------------------------------------------------------------------

@test "developer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "developer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.name'"
  assert_success
  assert_output "developer"
}

@test "developer.md has install-subagents in skills" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.skills[] | select(. == \"install-subagents\")'"
  assert_success
  assert_output "install-subagents"
}

@test "developer.md has effort field set to high" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.effort'"
  assert_success
  assert_output "high"
}

@test "developer.md has maxTurns field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.maxTurns'"
  assert_success
  assert_output "200"
}

@test "developer.md has disallowedTools including WebFetch and WebSearch" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.disallowedTools | length'"
  assert_success
  assert_output "2"
}

@test "developer.md has keep-coding-instructions set to true" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.\"keep-coding-instructions\"'"
  assert_success
  assert_output "true"
}

@test "developer.md has memory field set to project" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.memory'"
  assert_success
  assert_output "project"
}

# ---------------------------------------------------------------------------
# Cross-review aspect reviewers (5-aspect parallel, Sprint-end)
# ---------------------------------------------------------------------------

@test "requirement-conformance-reviewer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirement-conformance-reviewer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "requirement-conformance-reviewer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirement-conformance-reviewer.md' | yq -r '.name'"
  assert_success
  assert_output "requirement-conformance-reviewer"
}

@test "requirement-conformance-reviewer.md has tools restricted to read-only" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirement-conformance-reviewer.md' | yq '.tools | length'"
  assert_success
  assert_output "4"
}

@test "functional-quality-reviewer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/functional-quality-reviewer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "functional-quality-reviewer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/functional-quality-reviewer.md' | yq -r '.name'"
  assert_success
  assert_output "functional-quality-reviewer"
}

@test "functional-quality-reviewer.md has tools restricted to read-only" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/functional-quality-reviewer.md' | yq '.tools | length'"
  assert_success
  assert_output "4"
}

@test "maintainability-reviewer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/maintainability-reviewer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "maintainability-reviewer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/maintainability-reviewer.md' | yq -r '.name'"
  assert_success
  assert_output "maintainability-reviewer"
}

@test "maintainability-reviewer.md has tools restricted to read-only" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/maintainability-reviewer.md' | yq '.tools | length'"
  assert_success
  assert_output "4"
}

@test "docs-consistency-reviewer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/docs-consistency-reviewer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "docs-consistency-reviewer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/docs-consistency-reviewer.md' | yq -r '.name'"
  assert_success
  assert_output "docs-consistency-reviewer"
}

@test "docs-consistency-reviewer.md has tools restricted to read-only" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/docs-consistency-reviewer.md' | yq '.tools | length'"
  assert_success
  assert_output "4"
}

# Old reviewer agents (code-reviewer, codex-code-reviewer) deleted in
# 2026-05-07 cross-review multi-aspect refactor. Tests removed.

# ---------------------------------------------------------------------------
# security-reviewer.md
# ---------------------------------------------------------------------------

@test "security-reviewer.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/security-reviewer.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "security-reviewer.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/security-reviewer.md' | yq -r '.name'"
  assert_success
  assert_output "security-reviewer"
}

@test "security-reviewer.md has tools restricted to read-only" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/security-reviewer.md' | yq '.tools | length'"
  assert_success
  assert_output "4"
}

@test "security-reviewer.md has maxTurns field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/security-reviewer.md' | yq -r '.maxTurns'"
  assert_success
  assert_output "50"
}

