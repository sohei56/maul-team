#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/resolve-integrity.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/resolve-integrity.XXXXXX")"
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001/metrics docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  seed code 1
}

teardown() {
  rm -rf "$TEST_TMP"
}

seed() {
  local kind="$1" round="$2" status
  if [ "$kind" = docs ]; then status=in_progress_pbi_review; else status=in_progress_ut_run; fi
  jq -n --arg kind "$kind" --arg status "$status" '{items:[{
    id:"pbi-001", title:"Integrity gate test", status:$status,
    kind:$kind, created_at:"2026-08-11T00:00:00Z", updated_at:"2026-08-11T00:00:00Z"
  }]}' > .scrum/backlog.json
  jq -n --argjson round "$round" '{
    pbi_id:"pbi-001", design_round:1, impl_round:$round,
    design_status:"pass", impl_status:"pass", ut_status:"pass",
    coverage_status:"pass", escalation_reason:null,
    started_at:"2026-08-11T00:00:00Z", updated_at:"2026-08-11T00:00:00Z"
  }' > .scrum/pbi/pbi-001/state.json
  rm -f .scrum/pbi/pbi-001/metrics/integrity-r*.json
}

finding() {
  local signature="$1" severity="$2" aspect="$3"
  jq -nc --arg signature "$signature" --arg severity "$severity" --arg aspect "$aspect" \
    '{signature:$signature,severity:$severity,aspect:$aspect,description:"test"}'
}

aggregate() {
  local round="$1" file="$2" findings="$3" kind aspects
  kind="$(jq -r '.items[0].kind' .scrum/backlog.json)"
  if [ "$kind" = docs ]; then
    aspects='["requirement-conformance","docs-consistency"]'
  else
    aspects='["requirement-conformance","functional-quality","security","maintainability","docs-consistency"]'
  fi
  jq -n --argjson round "$round" --argjson aspects "$aspects" --argjson findings "$findings" \
    '{round:$round,aspects:$aspects,findings:$findings}' > "$file"
}

run_resolver() {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/resolve-integrity-fail.sh" pbi-001
}

@test "first Integrity aggregate skips comparison gates" {
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = next_round ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_impl ]
  [ "$(jq -r '.impl_status' .scrum/pbi/pbi-001/state.json)" = fail ]
}

@test "code PBI ignores sync-lag growth for divergence" {
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/old.md:1-1:stale_doc' critical docs-consistency)]"
  jq -n --argjson round 2 '.impl_round=$round | .pbi_id="pbi-001" | .design_round=1
    | .design_status="pass" | .impl_status="pass" | .ut_status="pass"
    | .coverage_status="pass" | .escalation_reason=null
    | .started_at="2026-08-11T00:00:00Z" | .updated_at="2026-08-11T00:00:00Z"' \
    > .scrum/pbi/pbi-001/state.json
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency),$(finding 'docs/b.md:1-1:stale_doc' critical requirement-conformance),$(finding 'docs/c.md:1-1:stale_doc' high docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = next_round ]
}

@test "code PBI detects increment growth even when total findings fall" {
  seed code 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/old.py:1-1:behavior' critical functional-quality),$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency),$(finding 'docs/b.md:1-1:stale_doc' critical docs-consistency)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'src/new.py:1-1:behavior' critical functional-quality),$(finding 'src/new.py:2-2:security' high security)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = divergence ]
  [ "$(jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json)" = divergence ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = escalated ]
}

@test "source count decrease is not divergence when docs count grows" {
  seed code 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/a.py:1-1:behavior' critical functional-quality),$(finding 'src/b.py:1-1:behavior' critical functional-quality)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'src/c.py:1-1:behavior' critical functional-quality),$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency),$(finding 'docs/b.md:1-1:stale_doc' critical requirement-conformance),$(finding 'docs/c.md:1-1:stale_doc' high docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = next_round ]
}

@test "docs PBI counts every blocking finding for divergence" {
  seed docs 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/old.md:1-1:stale_doc' critical docs-consistency)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency),$(finding 'docs/b.md:1-1:stale_doc' critical requirement-conformance)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = divergence ]
}

@test "stagnation uses all blocking signatures including docs" {
  seed code 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/same.md:4-4:stale_doc' critical docs-consistency)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'docs/same.md:4-4:stale_doc' critical docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = stagnation ]
}

@test "hard cap applies without a prior aggregate" {
  seed code 5
  aggregate 5 .scrum/pbi/pbi-001/metrics/integrity-r5.json \
    "[$(finding 'docs/a.md:1-1:stale_doc' high docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = max_rounds ]
}

@test "unknown aspect rejects transition" {
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/a.py:1-1:behavior' critical invented-aspect)]"

  run_resolver

  [ "$status" -ne 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_ut_run ]
  [ "$(jq -r '.impl_status' .scrum/pbi/pbi-001/state.json)" = pass ]
}

@test "malformed signature rejects transition" {
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'not-a-signature' critical security)]"

  run_resolver

  [ "$status" -ne 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_ut_run ]
}

@test "requirement-conformance non-md anchor is increment" {
  seed code 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/old.md:1-1:spec_mismatch' critical requirement-conformance)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'src/new.py:1-1:spec_mismatch' critical requirement-conformance)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = divergence ]
}

@test "docs-consistency remains sync_lag even with a non-md anchor" {
  seed code 2
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/old.md:1-1:stale_doc' critical docs-consistency)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'generated/reference.txt:1-1:stale_doc' critical docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = next_round ]
}

@test "prior filename and payload round mismatch rejects comparison" {
  seed code 2
  aggregate 9 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/old.py:1-1:behavior' critical functional-quality)]"
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'src/new.py:1-1:behavior' critical functional-quality)]"

  run_resolver

  [ "$status" -ne 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_ut_run ]
}

@test "aspects inconsistent with kind contract rejects transition" {
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/a.py:1-1:behavior' critical functional-quality)]"
  jq '.aspects = ["functional-quality"]' \
    .scrum/pbi/pbi-001/metrics/integrity-r1.json > aggregate.tmp
  mv aggregate.tmp .scrum/pbi/pbi-001/metrics/integrity-r1.json

  run_resolver

  [ "$status" -ne 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_ut_run ]
}

@test "code PBI rejects pbi-review entry status" {
  jq '.items[0].status = "in_progress_pbi_review"' .scrum/backlog.json > backlog.tmp
  mv backlog.tmp .scrum/backlog.json
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'src/a.py:1-1:behavior' critical functional-quality)]"

  run_resolver

  [ "$status" -ne 0 ]
  [[ "$output" == *"kind=code/status=in_progress_ut_run"* ]]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_pbi_review ]
}

@test "docs PBI rejects UT-run entry status" {
  seed docs 1
  jq '.items[0].status = "in_progress_ut_run"' .scrum/backlog.json > backlog.tmp
  mv backlog.tmp .scrum/backlog.json
  aggregate 1 .scrum/pbi/pbi-001/metrics/integrity-r1.json \
    "[$(finding 'docs/a.md:1-1:stale_doc' critical docs-consistency)]"

  run_resolver

  [ "$status" -ne 0 ]
  [[ "$output" == *"kind=docs/status=in_progress_pbi_review"* ]]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = in_progress_ut_run ]
}

@test "unused older malformed aggregate does not block selected valid prior" {
  seed code 3
  printf '%s\n' '{"round":99,"aspects":[],"findings":"broken"}' \
    > .scrum/pbi/pbi-001/metrics/integrity-r1.json
  aggregate 2 .scrum/pbi/pbi-001/metrics/integrity-r2.json \
    "[$(finding 'docs/old.md:1-1:stale_doc' critical docs-consistency)]"
  aggregate 3 .scrum/pbi/pbi-001/metrics/integrity-r3.json \
    "[$(finding 'docs/new.md:1-1:stale_doc' critical docs-consistency)]"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$output" = next_round ]
}
