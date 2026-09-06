#!/usr/bin/env bats
# Pins the three-Sprint whole-repo audit cadence without weakening the
# every-Sprint closeout or Integration-entry safety net.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CROSS_REVIEW="${PROJECT_ROOT}/skills/cross-review/SKILL.md"
  AUDIT="${PROJECT_ROOT}/skills/codebase-audit/SKILL.md"
  INTEGRATION="${PROJECT_ROOT}/skills/integration-tests/SKILL.md"
  PIPELINE="${PROJECT_ROOT}/skills/pbi-pipeline/SKILL.md"
  REQUIREMENTS="${PROJECT_ROOT}/docs/requirements.md"
  SM_AGENT="${PROJECT_ROOT}/agents/scrum-master.md"
  SCRUM_CONTEXT="${PROJECT_ROOT}/rules/scrum-context.md"
  SPRINT_PLANNING="${PROJECT_ROOT}/skills/sprint-planning/SKILL.md"
}

@test "cadence skips s1 and s2 and runs s3" {
  run bash -c 'for n in 1 2 3; do if (( n % 3 == 0 )); then printf "run "; else printf "skip "; fi; done'
  [ "$status" -eq 0 ]
  [ "$output" = "skip skip run " ]

  grep -q 'N % 3 != 0' "$CROSS_REVIEW"
  grep -q 'sprint-003.*sprint-006.*sprint-009' "$CROSS_REVIEW"
  grep -q 'execute \*\*only\*\* when `N % 3 == 0`' "$CROSS_REVIEW"
}

@test "non-due Sprint skips expensive work and creates no dummy report" {
  grep -q 'do not run static analysis, the four axes' "$CROSS_REVIEW"
  grep -q 'do not create placeholder audit/static-' "$CROSS_REVIEW"
  grep -q 'no `codebase-audit-s{N}.md` or static-analysis' "$CROSS_REVIEW"
  grep -q 'Continue directly at Step 8' "$CROSS_REVIEW"
  tr '\n' ' ' < "$CROSS_REVIEW" | grep -q 'Steps 5–7b.*execute \*\*only\*\* when `N % 3 == 0`'
  grep -q '^5\. \*\*Collect.*(due Sprints only)' "$CROSS_REVIEW"
  grep -q '^7b\. \*\*Close.*(due Sprints only)' "$CROSS_REVIEW"
}

@test "skip path still performs the PBI closeout transition" {
  local closeout
  closeout="$(awk '/^8\. \*\*Lightweight closeout:/{f=1} /^Ref:/{f=0} f' "$CROSS_REVIEW")"
  printf '%s' "$closeout" | grep -q 'status == "cross_review"'
  printf '%s' "$closeout" | grep -q 'update-backlog-status.sh.*done'
  grep -q 'cross_review → done.*still execute every Sprint' "$CROSS_REVIEW"
}

@test "Integration entry remains mandatory and missing report falls through to full audit" {
  grep -q 'mandatory preflight is cadence-independent' "$INTEGRATION"
  grep -q 'final non-due Sprint with no scheduled report' "$INTEGRATION"
  grep -q 'Report stale / missing' "$AUDIT"
  grep -q 'continue into Steps 1–5 with `context=integration_entry`' "$AUDIT"
  grep -q 'Do not substitute the most recent older scheduled' "$AUDIT"
  grep -q 'OPEN_BLOCKING > 0' "$AUDIT"
}

@test "scheduled audit preserves current-Sprint DOCS Step 7b" {
  local step5 step7b
  step5="$(awk '/^### Step 5 —/{f=1} /^### Step 6 —/{f=0} f' "$AUDIT")"
  step7b="$(awk '/^7b\. \*\*Close this scheduled audit/{f=1} /^8\. \*\*Lightweight closeout:/{f=0} f' "$CROSS_REVIEW")"
  printf '%s' "$step5" | grep -q 'CROSS_REVIEW_DOCS_PBI="$RESULT_PBI"'
  printf '%s' "$step5" | grep -q 'INTEGRATION_DOCS_PBI="$RESULT_PBI"'
  printf '%s' "$step7b" | grep -q 'Run it now, in this Sprint'
  printf '%s' "$step7b" | grep -q 'PBI="$CROSS_REVIEW_DOCS_PBI"'
  ! printf '%s' "$step7b" | grep -q '\$(\.scrum/scripts/add-backlog-item.sh'
  printf '%s' "$step7b" | grep -q 'contract violation: missing CROSS_REVIEW_DOCS_PBI'
  printf '%s' "$step7b" | grep -q 'The `kind=docs` pipeline runs'
  printf '%s' "$step7b" | grep -q 'Integrity aspects 1 + 5'
  printf '%s' "$step7b" | grep -q '^     draft)'
  printf '%s' "$step7b" | grep -q '^     escalated)'
  printf '%s' "$step7b" | grep -q 'escalated → in_progress_impl'
  printf '%s' "$step7b" | tr '\n' ' ' | grep -q 'operations.*exclusively to the new-`draft` branch'
}

@test "fresh Integration audit routes docs drift through fix loop before tests" {
  local step4 step5 closeout strict
  step4="$(awk '/^### Step 4 —/{f=1} /^### Step 4b —/{f=0} f' "$AUDIT")"
  step5="$(awk '/^### Step 5 —/{f=1} /^### Step 6 —/{f=0} f' "$AUDIT")"
  closeout="$(awk '/^### Step 6 —/{f=1} /^## Strict Rules/{f=0} f' "$AUDIT")"
  strict="$(awk '/^## Strict Rules/{f=1} /^## Exit Criteria/{f=0} f' "$AUDIT")"
  printf '%s' "$step4" | tr '\n' ' ' | grep -q 'remove the synthetic DOCS finding from the PO'
  printf '%s' "$step5" | grep -q 'MANDATORY_INTEGRATION_DOCS'
  printf '%s' "$step5" | tr '\n' ' ' | grep -q 'required \*\*reuse\*\* path'
  printf '%s' "$step5" | tr '\n' ' ' | grep -q 'required \*\*file\*\* path'
  printf '%s' "$step5" | tr '\n' ' ' | grep -Eq 'regardless of a[[:space:]]+PO `defer`/`reject`'
  printf '%s' "$closeout" | tr '\n' ' ' | grep -q 'INTEGRATION_DOCS_PBI.*MUST enter the normal defect-fix loop'
  printf '%s' "$closeout" | grep -q 'regardless of `audit_severity`'
  printf '%s' "$closeout" | grep -q 'update-state-phase.sh backlog_created'
  printf '%s' "$strict" | grep -q 'DOCS batch at any severity'
  grep -q 'completed through the normal fix loop before' "$INTEGRATION"
}

@test "operational SSOTs all expose the every-third-Sprint audit cadence" {
  grep -q 'only when `N % 3 == 0`' "$REQUIREMENTS"
  grep -q 'only when `N % 3 == 0`' "$SM_AGENT"
  grep -q 'only N % 3 == 0 runs' "$SCRUM_CONTEXT"
  grep -q 'audit only when `N % 3 == 0`' "$SPRINT_PLANNING"
}

@test "per-PBI docs consistency remains always on for code and docs PBIs" {
  local code_path docs_path
  code_path="$(awk '/^### kind=code/{f=1} /^### kind=docs/{f=0} f' "$PIPELINE")"
  docs_path="$(awk '/^### kind=docs/{f=1} /^## /&&f&&$0!~/^### kind=docs/{f=0} f' "$PIPELINE")"
  printf '%s' "$code_path" | grep -q 'docs-consistency'
  printf '%s' "$docs_path" | grep -q 'requirement-conformance + docs-consistency reviewers only'
}
