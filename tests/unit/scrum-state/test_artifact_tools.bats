#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/artifact-tools.XXXXXX")"
  mkdir -p "$TEST_TMP/.scrum"
  cd "$TEST_TMP" || exit 1
  CLEANUP="$PROJECT_ROOT/scripts/scrum/cleanup-artifacts.sh"
  INDEX="$PROJECT_ROOT/scripts/scrum/generate-sprint-index.sh"
}

teardown() { rm -rf "$TEST_TMP"; }

@test "cleanup is dry-run by default and apply removes only disposable artifacts" {
  mkdir -p .scrum/rollups/run-1 .scrum/rollups/run-2 \
    .scrum/worktrees/pbi-001/.venv .scrum/worktrees/pbi-001/src \
    .scrum/framework-issues .scrum/pbi/pbi-001 .scrum/reviews .scrum/po/acceptance/sprint-001
  printf 'success\n' > .scrum/rollups/run-1/status
  printf 'failed\n' > .scrum/rollups/run-2/status
  printf raw > .scrum/rollups/run-1/stdout
  printf evidence > .scrum/rollups/run-2/stderr
  printf env > .scrum/worktrees/pbi-001/.venv/file
  printf source > .scrum/worktrees/pbi-001/src/app.py
  printf body > .scrum/framework-issues/sprint-001-01.md
  printf 'status=posted\nposted_url=https://example.test/1\n' > .scrum/framework-issues/sprint-001-01.meta
  printf pbi > .scrum/pbi/pbi-001/review.md
  printf review > .scrum/reviews/result.json
  printf po > .scrum/po/acceptance/sprint-001/pbi-001.md

  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [ -f .scrum/rollups/run-1/stdout ]

  run "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ ! -e .scrum/rollups/run-1/stdout ]
  [ -f .scrum/rollups/run-2/stderr ]
  [ ! -e .scrum/worktrees/pbi-001/.venv ]
  [ -f .scrum/worktrees/pbi-001/src/app.py ]
  [ ! -e .scrum/framework-issues/sprint-001-01.md ]
  [ -f .scrum/framework-issues/sprint-001-01.meta ]
  [ -f .scrum/pbi/pbi-001/review.md ]
  [ -f .scrum/reviews/result.json ]
  [ -f .scrum/po/acceptance/sprint-001/pbi-001.md ]
}

@test "cleanup bounds runtime logs but preserves evidence logs" {
  mkdir -p .scrum/pbi/pbi-001
  printf '1234567890' > .scrum/hooks.log
  printf '1234567890' > .scrum/pbi/pbi-001/merge-regression.log
  run env SCRUM_ARTIFACT_MAX_LOG_BYTES=4 "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ "$(cat .scrum/hooks.log)" = "7890" ]
  [ "$(cat .scrum/pbi/pbi-001/merge-regression.log)" = "1234567890" ]
}

@test "cleanup removes only an old lock whose recorded owner is dead" {
  mkdir -p .scrum/locks/dead.lock.d .scrum/locks/live.lock.d .scrum/locks/unknown.lock.d
  printf '99999999\n' > .scrum/locks/dead.lock.d/owner.pid
  printf '%s\n' "$$" > .scrum/locks/live.lock.d/owner.pid
  run env SCRUM_ARTIFACT_MIN_LOCK_AGE_SEC=0 "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ ! -e .scrum/locks/dead.lock.d ]
  [ -d .scrum/locks/live.lock.d ]
  [ -d .scrum/locks/unknown.lock.d ]
}

@test "cleanup retains a live lock when kill -0 is permission-denied" {
  mkdir -p .scrum/locks/eperm.lock.d
  printf '%s\n' "$$" > .scrum/locks/eperm.lock.d/owner.pid
  printf '%s\n' 'kill() { return 1; }' > "$TEST_TMP/force-eperm.bash"
  run env BASH_ENV="$TEST_TMP/force-eperm.bash" \
    SCRUM_ARTIFACT_MIN_LOCK_AGE_SEC=0 "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ -d .scrum/locks/eperm.lock.d ]
}

@test "artifact tools never touch stock-bo-monitoring-system .scrum fixture" {
  mkdir -p "$TEST_TMP/stock-bo-monitoring-system/.scrum/rollups/run-1"
  printf success > "$TEST_TMP/stock-bo-monitoring-system/.scrum/rollups/run-1/status"
  printf sentinel > "$TEST_TMP/stock-bo-monitoring-system/.scrum/rollups/run-1/stdout"
  cd "$TEST_TMP/stock-bo-monitoring-system" || exit 1
  run "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ "$(cat .scrum/rollups/run-1/stdout)" = sentinel ]
  run "$INDEX"
  [ "$status" -eq 0 ]
  [ ! -e .scrum/sprint-index.md ]
}

@test "sprint index is compact and leaves authoritative inputs unchanged" {
  printf '%s\n' '{"sprints":[{"id":"sprint-001","goal":"Ship | safely","pbis_completed":2,"pbis_total":3,"completed_at":"2026-08-09T00:00:00Z"}]}' > .scrum/sprint-history.json
  before="$(shasum .scrum/sprint-history.json | awk '{print $1}')"
  run "$INDEX"
  [ "$status" -eq 0 ]
  [ "$output" = ".scrum/sprint-index.md" ]
  grep -qF '| sprint-001 | Ship   safely | 2026-08-09T00:00:00Z | 2/3 |' .scrum/sprint-index.md
  [ "$(shasum .scrum/sprint-history.json | awk '{print $1}')" = "$before" ]
}
