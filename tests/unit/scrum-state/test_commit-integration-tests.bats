#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WRAPPER="$PROJECT_ROOT/scripts/scrum/commit-integration-tests.sh"
  TEST_TMP="$(mktemp -d /tmp/claude/commit-int-tests.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/commit-int-tests.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  write_phase integration_sprint
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

write_phase() {
  cat > .scrum/state.json <<EOF
{"phase":"$1","created_at":"2026-07-04T10:00:00Z","updated_at":"2026-07-04T10:00:00Z"}
EOF
}

@test "commit-integration-tests: refuses when phase is not integration_sprint" {
  write_phase pbi_pipeline_active
  mkdir -p tests/integration
  echo "def test_x(): pass" > tests/integration/test_x.py
  run "$WRAPPER" "add api tests"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "integration_sprint"
}

@test "commit-integration-tests: refuses on a pbi/* worktree branch" {
  git checkout -q -b pbi/pbi-001
  mkdir -p tests/integration
  echo "def test_x(): pass" > tests/integration/test_x.py
  run "$WRAPPER" "add api tests"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "branch"
}

@test "commit-integration-tests: commits files under tests/" {
  mkdir -p tests/integration tests/e2e tests/stubs
  echo "def test_x(): pass" > tests/integration/test_x.py
  echo "// e2e" > tests/e2e/flow.spec.ts
  echo "stub" > tests/stubs/server.py
  run "$WRAPPER" "add integration + e2e + stub assets"
  [ "$status" -eq 0 ]
  run git log -1 --pretty=%s
  [ "$output" = "test(integration): add integration + e2e + stub assets" ]
  # All three assets landed in the commit.
  run git show --stat --name-only --pretty=format: HEAD
  echo "$output" | grep -q "tests/integration/test_x.py"
  echo "$output" | grep -q "tests/e2e/flow.spec.ts"
  echo "$output" | grep -q "tests/stubs/server.py"
}

@test "commit-integration-tests: refuses when a non-allowlisted path is staged" {
  mkdir -p src tests/integration
  echo "print('app')" > src/app.py
  git add src/app.py
  echo "def test_x(): pass" > tests/integration/test_x.py
  run "$WRAPPER" "add api tests"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "src/app.py"
  # Nothing was committed.
  run git log -1 --pretty=%s
  [ "$output" = "init" ]
}

@test "commit-integration-tests: --allow admits an exception path" {
  mkdir -p tests/integration
  echo "def test_x(): pass" > tests/integration/test_x.py
  echo "[pytest]" > pytest.ini
  run "$WRAPPER" "add api tests + runner config" --allow pytest.ini
  [ "$status" -eq 0 ]
  run git show --stat --name-only --pretty=format: HEAD
  echo "$output" | grep -q "tests/integration/test_x.py"
  echo "$output" | grep -q "pytest.ini"
  # The --allow path is recorded in the commit body for audit.
  run git log -1 --pretty=%b
  echo "$output" | grep -q "pytest.ini"
}

@test "commit-integration-tests: noops cleanly when nothing to commit" {
  run "$WRAPPER" "nothing here"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "nothing to commit"
  run git log -1 --pretty=%s
  [ "$output" = "init" ]
}
