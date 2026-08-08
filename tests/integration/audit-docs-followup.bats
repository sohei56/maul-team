#!/usr/bin/env bats
# tests/integration/audit-docs-followup.bats — cross-review Step 7b, exercised
# against the real wrappers.
#
# Step 7b files the audit's documentation batch into the CURRENT Sprint and
# drives it to merge, so the drift does not compound while it waits. That path
# crosses several guards that were written assuming no PBI is created after
# Sprint Planning. This test walks the wrapper sequence the skill prescribes
# and pins the three that could silently break it.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/docs-followup.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/docs-followup.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  for s in backlog sprint pbi-state state; do
    cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/
  done

  git init -q
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "sprint base"
  BASE_SHA="$(git rev-parse HEAD)"

  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/init-state.sh" >/dev/null
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/init-backlog.sh" --product-goal "followup" >/dev/null
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/init-sprint.sh" sprint-001 --goal "g" >/dev/null
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh" >/dev/null

  # The Sprint's own PBIs merged after the base was frozen — which is exactly
  # why Step 7b cannot reuse sprint.base_sha.
  git commit -q --allow-empty -m "sprint PBIs merged"
  HEAD_SHA="$(git rev-parse HEAD)"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

scrum() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/$@"
}

@test "step 7b: the wrapper sequence files and prepares a docs PBI mid-Sprint" {
  PBI="$(scrum add-backlog-item.sh \
    --title "[codebase-audit:sprint-001:DOCS:High] stale references" \
    --audit-identity "docs-drift::stale-references" --audit-severity high \
    --description "docs/architecture.md:12 — stale anchor. See report." \
    --ac "docs/architecture.md §2 states the current module map" \
    --kind docs)"

  # kind=docs is demo_plan-exempt, so ->refined needs no extra field. If that
  # exemption ever went away, Step 7b could not refine its own PBI.
  run scrum update-backlog-status.sh "$PBI" refined
  [ "$status" -eq 0 ]

  # sprint_id is assignable while the Sprint is already running.
  run scrum set-backlog-item-field.sh "$PBI" sprint_id sprint-001
  [ "$status" -eq 0 ]
  run scrum set-backlog-item-field.sh "$PBI" implementer_id dev-001-s1
  [ "$status" -eq 0 ]

  scrum init-pbi-state.sh "$PBI" >/dev/null
  run scrum create-pbi-worktree.sh "$PBI" --base "$HEAD_SHA"
  [ "$status" -eq 0 ]

  # The worktree must contain this Sprint's merges — a tree forked from
  # sprint.base_sha would predate the drift the audit reported.
  run git -C ".scrum/worktrees/$PBI" rev-parse HEAD
  [ "$output" = "$HEAD_SHA" ]
  [ "$output" != "$BASE_SHA" ]
}

@test "step 7b: the docs PBI reaches done through the kind=docs status path" {
  PBI="$(scrum add-backlog-item.sh \
    --title "[codebase-audit:sprint-001:DOCS:High] stale references" \
    --audit-identity "docs-drift::stale-references" --audit-severity high \
    --ac "a passage states the current map" --kind docs)"
  scrum update-backlog-status.sh "$PBI" refined
  scrum set-backlog-item-field.sh "$PBI" sprint_id sprint-001

  # kind=docs skips design and ut_run entirely (data-model § kind=docs override).
  for s in in_progress_impl in_progress_pbi_review in_progress_merge awaiting_cross_review cross_review done; do
    run scrum update-backlog-status.sh "$PBI" "$s"
    [ "$status" -eq 0 ]
  done
  run jq -r --arg id "$PBI" '.items[] | select(.id == $id) | .status' .scrum/backlog.json
  [ "$output" = "done" ]
}

@test "step 7b: the batch keeps its fixed identity so a later audit dedups it" {
  PBI="$(scrum add-backlog-item.sh \
    --title "[codebase-audit:sprint-001:DOCS:High] stale references" \
    --audit-identity "docs-drift::stale-references" --audit-severity high \
    --ac "a passage states the current map" --kind docs)"
  run jq -r --arg id "$PBI" '.items[] | select(.id == $id) | .audit_identity' .scrum/backlog.json
  [ "$output" = "docs-drift::stale-references" ]
}
