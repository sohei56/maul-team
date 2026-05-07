#!/usr/bin/env bats
setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/safe-switch-to-main.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/safe-switch-to-main.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "safe-switch-to-main: no-op when already on main" {
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already on main"
}

@test "safe-switch-to-main: switches from feature branch to main" {
  git checkout -q -b feature/test
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/test" ]
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "now on main"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "safe-switch-to-main: rejects extra args" {
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh" extra
  [ "$status" -ne 0 ]
}

@test "safe-switch-to-main: refuses when working tree has tracked changes" {
  git checkout -q -b feature/test
  echo "x" > tracked.txt
  git add tracked.txt
  PRE_HEAD="$(git rev-parse HEAD)"
  PRE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "uncommitted tracked changes"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$PRE_BRANCH" ]
  [ "$(git rev-parse HEAD)" = "$PRE_HEAD" ]
}

@test "safe-switch-to-main: refuses when .scrum/ is tracked" {
  mkdir -p .scrum
  echo "{}" > .scrum/state.json
  git add -f .scrum/state.json
  git commit -q -m "track scrum"
  git checkout -q -b feature/test
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "tracked in git"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/test" ]
}

@test "safe-switch-to-main: untracked files do not block switch" {
  git checkout -q -b feature/test
  echo "junk" > untracked.txt  # not added
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "safe-switch-to-main: refuses when 'main' branch missing" {
  git branch -m main trunk
  run "$PROJECT_ROOT/scripts/scrum/safe-switch-to-main.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "branch 'main' does not exist"
}
