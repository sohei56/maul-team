#!/usr/bin/env bats
# tests/integration/detector-merge-gate.bats — the guard-first ratchet,
# exercised end to end against the real merge wrapper.
#
# This is the check the rollout depends on. The unit tests cover the runner's
# exit space; this covers the decision the SM actually acts on: a PBI that
# reintroduces a guarded defect class must NOT reach main, must leave main at
# its pre-merge HEAD, must record merge_failure.kind=detector_regression with
# a log naming the offending file, and must escalate on the third strike as
# merge_detector_regression.
#
# The ledger is written directly here (a test is not an agent tool call, so
# the scrum-state guard does not apply); in production it is written only by
# scripts/scrum/update-audit-ledger.sh.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/detector-gate.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/detector-gate.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do
    cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/
  done

  git init -q -b main
  git config user.email t@t; git config user.name t
  echo "clean" > seed.txt
  git add seed.txt
  git commit -q -m "init"
  SHA="$(git rev-parse HEAD)"

  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress_ut_run"}]}
EOF

  IDENTITY="forbidden-token::literal-forbidden"
  # A real detector: prints `path:line: text` for each hit and exits 1, silent
  # exit 0 when clean. .git and .scrum are excluded — the ledger itself stores
  # the token as part of this very command, and the PBI worktree lives under
  # .scrum/worktrees/.
  DETECTOR_CMD='if grep -rn --exclude-dir=.git --exclude-dir=.scrum FORBIDDEN . ; then exit 1; fi'
  export IDENTITY DETECTOR_CMD PROJECT_ROOT TEST_TMP
}

teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

# write_ledger <status>
write_ledger() {
  jq -n --arg k "$IDENTITY" --arg c "$DETECTOR_CMD" --arg s "$1" \
    '{updated_at: "2026-05-04T10:00:00Z",
      classes: [{identity: $k, axis: ["logic-defect"], severity: "high",
                 status: $s, occurrences: [],
                 detector: {command: $c, registered_sprint: "sprint-001",
                            verified_at: "2026-05-04T10:00:00Z", verified_exit: 0},
                 pbi_ids: [{id: "pbi-001", role: "sweep"}],
                 first_seen_sprint: "sprint-001"}]}' > .scrum/audit-ledger.json
}

# Build the PBI branch. <file-content> lands in violating.txt on the branch.
prepare_pbi() {
  local content="$1"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001 >/dev/null
  printf '%s\n' "$content" > .scrum/worktrees/pbi-001/violating.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: add file" >/dev/null
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001 >/dev/null
}

merge() {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli \
    "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
}

@test "detector gate: a PBI reintroducing a guarded class is rejected and main is rolled back" {
  write_ledger guarded
  prepare_pbi "this line contains FORBIDDEN text"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"

  run merge
  # exit 2 = a merge failure was recorded this attempt (the SM failure matrix).
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "detector_regression"

  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "detector_regression" ]
  run jq -r '.merge_failure.paths[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = ".scrum/pbi/pbi-001/detector-regression.log" ]

  # main is exactly where it was: the violation never reaches it.
  [ "$(git rev-parse HEAD)" = "$PRE_MAIN_HEAD" ]
  ! git log --oneline main | grep -q "merge: pbi-001"
  [ ! -f violating.txt ]

  # The log names the offending file and the class that owns it.
  [ -f .scrum/pbi/pbi-001/detector-regression.log ]
  grep -q "violating.txt" .scrum/pbi/pbi-001/detector-regression.log
  grep -q "\[$IDENTITY\]" .scrum/pbi/pbi-001/detector-regression.log

  # Below the 3-strike threshold: the Developer retries, status unchanged.
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
  # The worktree survives the rollback so the Developer can fix in place.
  [ -d .scrum/worktrees/pbi-001 ]
}

@test "detector gate: the failure message names the ledger escape hatch" {
  write_ledger guarded
  prepare_pbi "FORBIDDEN"
  run merge
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "update-audit-ledger.sh set-status"
  echo "$output" | grep -q -- "--status open"
}

@test "detector gate: three strikes escalate as merge_detector_regression" {
  write_ledger guarded
  prepare_pbi "FORBIDDEN"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"

  # Each attempt merges, trips the detector, rolls main back, and increments
  # merge_failure_count. Nothing about the branch changes between attempts —
  # this is the SM retrying after a Developer re-notification that did not
  # actually fix the class.
  run merge
  [ "$status" -eq 2 ]
  [ "$(jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json)" = "1" ]
  [ "$(jq -r '.escalation_reason // "unset"' .scrum/pbi/pbi-001/state.json)" = "unset" ]

  run merge
  [ "$status" -eq 2 ]
  [ "$(jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json)" = "2" ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = "in_progress_merge" ]

  run merge
  [ "$status" -eq 2 ]
  [ "$(jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json)" = "3" ]
  [ "$(jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json)" = "merge_detector_regression" ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = "escalated" ]

  # Three merge attempts, zero of them on main.
  [ "$(git rev-parse HEAD)" = "$PRE_MAIN_HEAD" ]
}

@test "detector gate: a clean PBI merges normally with the ledger present" {
  write_ledger guarded
  prepare_pbi "nothing to see here"

  run merge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = "awaiting_cross_review" ]
  git log --oneline main | grep -q "merge: pbi-001"
  # Silent success leaves no stray log behind.
  [ ! -f .scrum/pbi/pbi-001/detector-regression.log ]
}

@test "detector gate: a class that is not guarded does not gate the merge" {
  # `sweeping` means the class is still being fixed — the ratchet is not live
  # yet, so the same violating content must merge.
  write_ledger sweeping
  prepare_pbi "this line contains FORBIDDEN text"

  run merge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = "awaiting_cross_review" ]
  [ -f violating.txt ]
}

@test "detector gate: fail-closed — a BROKEN detector fails the merge (runner exit 2)" {
  # The measured failure this gate exists to prevent: the ledger claims a
  # guarded class while nothing actually checks it. A detector that cannot
  # execute must never be read as clean.
  jq -n --arg k "$IDENTITY" \
    '{classes: [{identity: $k, status: "guarded", first_seen_sprint: "sprint-001",
                 detector: {command: "definitely-not-a-real-command-xyz",
                            registered_sprint: "sprint-001",
                            verified_at: "2026-05-04T10:00:00Z", verified_exit: 0}}]}' \
    > .scrum/audit-ledger.json
  prepare_pbi "perfectly innocent content"
  PRE_MAIN_HEAD="$(git rev-parse HEAD)"

  run merge
  [ "$status" -eq 2 ]
  [ "$(jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json)" = "detector_regression" ]
  [ "$(git rev-parse HEAD)" = "$PRE_MAIN_HEAD" ]
  grep -q "DETECTOR COULD NOT EXECUTE" .scrum/pbi/pbi-001/detector-regression.log
}

@test "detector gate: no ledger at all → merge behaves exactly as before" {
  prepare_pbi "this line contains FORBIDDEN text"
  run merge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[0].status' .scrum/backlog.json)" = "awaiting_cross_review" ]
  # No ledger means no gate and no artifact — byte-identical to a target that
  # never adopted guard-first detectors.
  [ ! -f .scrum/pbi/pbi-001/detector-regression.log ]
}

@test "detector gate: detectors run BEFORE the project regression command" {
  # Ordering matters: a slow suite must not mask a cheap, class-specific
  # detector. A regression command that would also fail must never be the one
  # that gets recorded.
  write_ledger guarded
  cat > .scrum/config.json <<'EOF'
{"merge_regression":{"command":"echo REGRESSION-RAN > regression-marker.txt; exit 1"}}
EOF
  prepare_pbi "FORBIDDEN"

  run merge
  [ "$status" -eq 2 ]
  [ "$(jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json)" = "detector_regression" ]
  [ ! -f regression-marker.txt ]
}
