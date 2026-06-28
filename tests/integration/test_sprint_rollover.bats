#!/usr/bin/env bats
# test_sprint_rollover.bats — end-to-end Sprint 1 → Sprint 2 rollover.
#
# Regression guard for the autonomous-run blocker where the team could not
# advance past Sprint 1: init-sprint.sh refused while sprint.json existed and
# freeze-sprint-base.sh refused while base_sha was frozen, with no sanctioned
# wrapper to archive-and-clear the completed Sprint. This drives the REAL
# wrappers through a full rollover and asserts the next Sprint can start on a
# fresh base.

load '../test_helper/common-setup'

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=python
  setup_temp_dir
  export PROJECT_ROOT
  S="$PROJECT_ROOT/scripts/scrum"
  cd "$TEMP_DIR" || exit 1

  # freeze-sprint-base.sh captures `git rev-parse HEAD`, so the project must be
  # a git repo with at least one commit.
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "seed" > README.md
  git add README.md
  git commit -q -m "sprint-1 base"
  BASE1="$(git rev-parse HEAD)"

  bash "$S/init-state.sh" >/dev/null
}

teardown() {
  teardown_temp_dir
}

@test "sprint rollover: a completed Sprint 1 lets Sprint 2 start on a fresh base" {
  # --- Sprint 1 ---
  run bash "$S/init-sprint.sh" sprint-001 --goal "Sprint 1 goal"
  [ "$status" -eq 0 ]
  run bash "$S/freeze-sprint-base.sh"
  [ "$status" -eq 0 ]
  assert_json_match .scrum/sprint.json '.base_sha' "$BASE1"
  bash "$S/update-sprint-status.sh" complete >/dev/null

  # Pre-condition the rollover fixes: while sprint.json exists, a second
  # init-sprint and a re-freeze are BOTH refused.
  run bash "$S/init-sprint.sh" sprint-002 --goal "Sprint 2 goal"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  run bash "$S/freeze-sprint-base.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already frozen"* ]]

  # --- Rollover ---
  run bash "$S/rollover-sprint.sh"
  [ "$status" -eq 0 ]
  [ ! -f .scrum/sprint.json ]
  assert_json_match .scrum/sprint-history.json '.sprints[-1].id' "sprint-001"
  assert_json_match .scrum/sprint-history.json '.sprints[-1].goal' "Sprint 1 goal"

  # Simulate Sprint 1 work landing on main → main HEAD advances.
  echo "pbi-001" > feature.txt
  git add feature.txt
  git commit -q -m "pbi-001 merged"
  BASE2="$(git rev-parse HEAD)"
  [ "$BASE2" != "$BASE1" ]

  # --- Sprint 2 now starts cleanly on the fresh base ---
  run bash "$S/init-sprint.sh" sprint-002 --goal "Sprint 2 goal"
  [ "$status" -eq 0 ]
  assert_json_match .scrum/sprint.json '.id' "sprint-002"
  assert_json_match .scrum/state.json '.current_sprint_id' "sprint-002"

  run bash "$S/freeze-sprint-base.sh"
  [ "$status" -eq 0 ]
  # The new Sprint's base is the CURRENT main HEAD, not the stale Sprint-1 base.
  assert_json_match .scrum/sprint.json '.base_sha' "$BASE2"
}

@test "sprint rollover: history accumulates one entry per rolled-over Sprint" {
  bash "$S/init-sprint.sh" sprint-001 --goal "S1" >/dev/null
  bash "$S/update-sprint-status.sh" complete >/dev/null
  bash "$S/rollover-sprint.sh" >/dev/null

  bash "$S/init-sprint.sh" sprint-002 --goal "S2" >/dev/null
  bash "$S/update-sprint-status.sh" complete >/dev/null
  bash "$S/rollover-sprint.sh" >/dev/null

  run jq -r '.sprints | length' .scrum/sprint-history.json
  [ "$output" = "2" ]
  run jq -r '[.sprints[].id] | join(",")' .scrum/sprint-history.json
  [ "$output" = "sprint-001,sprint-002" ]
}
