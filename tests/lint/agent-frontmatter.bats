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

@test "scrum-master.md has skills field with 14 entries" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/scrum-master.md' | yq '.skills | length'"
  assert_success
  assert_output "14"
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

@test "developer.md has tools allowlist with 11 entries" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.tools | length'"
  assert_success
  assert_output "11"
}

@test "developer.md tools allowlist includes WebSearch and WebFetch" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.tools | contains([\"WebSearch\", \"WebFetch\"])'"
  assert_success
  assert_output "true"
}

@test "developer.md does not list requirement-definition skill" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.skills | contains([\"requirement-definition\"])'"
  assert_success
  assert_output "false"
}

@test "developer.md tools allowlist includes Agent" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.tools | contains([\"Agent\"])'"
  assert_success
  assert_output "true"
}

@test "developer.md has no disallowedTools key" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq '.disallowedTools'"
  assert_success
  assert_output "null"
}

@test "developer.md has memory field set to project" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/developer.md' | yq -r '.memory'"
  assert_success
  assert_output "project"
}

# ---------------------------------------------------------------------------
# requirements-analyst.md (Requirement Definition ceremony)
# ---------------------------------------------------------------------------

@test "requirements-analyst.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "requirements-analyst.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq -r '.name'"
  assert_success
  assert_output "requirements-analyst"
}

@test "requirements-analyst.md owns requirement-definition skill" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq '.skills | contains([\"requirement-definition\"])'"
  assert_success
  assert_output "true"
}

@test "requirements-analyst.md tools include WebSearch and WebFetch (mandatory benchmark research)" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq '.tools | contains([\"WebSearch\", \"WebFetch\"])'"
  assert_success
  assert_output "true"
}

@test "requirements-analyst.md does not have Agent tool (not a pipeline conductor)" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq '.tools | contains([\"Agent\"])'"
  assert_success
  assert_output "false"
}

@test "requirements-analyst.md has memory field set to project" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/requirements-analyst.md' | yq -r '.memory'"
  assert_success
  assert_output "project"
}

# ---------------------------------------------------------------------------
# Integrity-stage aspect reviewers (5-aspect parallel, per-PBI;
# Developer-spawned in the PBI pipeline's Integrity stage)
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
# product-owner.md
# ---------------------------------------------------------------------------

@test "product-owner.md has valid YAML frontmatter" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq '.' > /dev/null 2>&1"
  assert_success
}

@test "product-owner.md has required name field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.name'"
  assert_success
  assert_output "product-owner"
}

@test "product-owner.md has description field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.description'"
  assert_success
  refute_output ""
}

@test "product-owner.md has model field set to opus" {
  # The source default. scrum-start.sh --autonomous patches the deployed copy
  # at .claude/agents/product-owner.md to .scrum/config.json.autonomous.po_model
  # (defaults to opus, overridable by --po-model).
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.model'"
  assert_success
  assert_output "opus"
}

@test "product-owner.md has effort field set to xhigh" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.effort'"
  assert_success
  assert_output "xhigh"
}

@test "product-owner.md has maxTurns field" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.maxTurns'"
  assert_success
  assert_output "300"
}

@test "product-owner.md has disallowedTools including WebFetch and WebSearch" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq '.disallowedTools | length'"
  assert_success
  assert_output "2"
}

@test "product-owner.md has memory field set to project" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq -r '.memory'"
  assert_success
  assert_output "project"
}

@test "product-owner.md has po-acceptance in skills" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/product-owner.md' | yq '.skills[] | select(. == \"po-acceptance\")'"
  assert_success
  assert_output "po-acceptance"
}

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
  assert_output "80"
}

# ---------------------------------------------------------------------------
# pbi-designer.md (mandatory library selection web search)
# ---------------------------------------------------------------------------

@test "pbi-designer.md tools include WebSearch and WebFetch (mandatory library research)" {
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/pbi-designer.md' | yq '.tools | contains([\"WebSearch\", \"WebFetch\"])'"
  assert_success
  assert_output "true"
}

@test "pbi-designer.md does not disallow WebSearch/WebFetch" {
  # coalesce null (field absent) to [] so contains() never errors
  run bash -c "awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' '${PROJECT_ROOT}/agents/pbi-designer.md' | yq '(.disallowedTools // []) | contains([\"WebSearch\", \"WebFetch\"])'"
  assert_success
  assert_output "false"
}

