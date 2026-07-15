#!/usr/bin/env bats

setup() {
  TEST_TMP="$(mktemp -d /tmp/claude/path-guard-test.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/path-guard-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  cat > .scrum/config.json <<'EOF'
{
  "path_guard": {
    "impl_globs": ["src/**"],
    "test_globs": ["tests/**"]
  }
}
EOF
  HOOK="${BATS_TEST_DIRNAME}/../../hooks/pre-tool-use-path-guard.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Helper to send payload via stdin
payload() {
  local agent="$1" tool="$2" path="$3"
  jq -n --arg a "$agent" --arg t "$tool" --arg p "$path" \
    '{agent_name: $a, tool_name: $t, tool_input: {file_path: $p}}'
}

@test "blocks pbi-ut-author from reading impl path" {
  run bash -c "echo '$(payload pbi-ut-author Read src/auth.py)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "blocks pbi-ut-author from writing impl path" {
  run bash -c "echo '$(payload pbi-ut-author Write src/auth.py)' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "allows pbi-ut-author to read test path" {
  run bash -c "echo '$(payload pbi-ut-author Read tests/test_auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows pbi-ut-author to read design doc" {
  run bash -c "echo '$(payload pbi-ut-author Read .scrum/pbi/pbi-001/design/design.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks pbi-implementer from writing test path" {
  run bash -c "echo '$(payload pbi-implementer Write tests/test_auth.py)' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "allows pbi-implementer to read test path (read-only)" {
  run bash -c "echo '$(payload pbi-implementer Read tests/test_auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows pbi-implementer to write src path" {
  run bash -c "echo '$(payload pbi-implementer Write src/auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "passes through unknown agent" {
  run bash -c "echo '$(payload other-agent Read src/auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks Bash for pbi-ut-author" {
  run bash -c "echo '{\"agent_name\":\"pbi-ut-author\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/auth.py\"}}' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "blocks Bash for pbi-implementer" {
  run bash -c "echo '{\"agent_name\":\"pbi-implementer\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee tests/test_auth.py\"}}' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "passes through when .scrum/config.json missing" {
  rm -f .scrum/config.json
  run bash -c "echo '$(payload pbi-ut-author Read src/auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# product-owner path sandbox
# ---------------------------------------------------------------------------

@test "allows product-owner to write docs/product/vision.md" {
  mkdir -p docs/product
  run bash -c "echo '$(payload product-owner Write docs/product/vision.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows product-owner to edit docs/product/brief.md" {
  mkdir -p docs/product
  run bash -c "echo '$(payload product-owner Edit docs/product/brief.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows product-owner to write .scrum/po/attention.md" {
  mkdir -p .scrum/po
  run bash -c "echo '$(payload product-owner Write .scrum/po/attention.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows product-owner to write nested .scrum/po path" {
  mkdir -p .scrum/po/acceptance/sprint-1
  run bash -c "echo '$(payload product-owner Write .scrum/po/acceptance/sprint-1/pbi-001.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks product-owner from writing src/main.py" {
  run bash -c "echo '$(payload product-owner Write src/main.py)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "blocks product-owner from editing tests/test_main.py" {
  run bash -c "echo '$(payload product-owner Edit tests/test_main.py)' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "allows product-owner Bash (app launch / verification)" {
  run bash -c "echo '{\"agent_name\":\"product-owner\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"curl -sf http://localhost:3000/healthz\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "product-owner sandbox holds when .scrum/config.json missing" {
  rm -f .scrum/config.json
  run bash -c "echo '$(payload product-owner Write src/main.py)' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "product-owner allowed paths still allowed when config missing" {
  rm -f .scrum/config.json
  mkdir -p docs/product
  run bash -c "echo '$(payload product-owner Write docs/product/vision.md)' | $HOOK"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Worktree-prefix normalization (RC#12 / T1-9): PBI work runs in
# .scrum/worktrees/<pbi-id>/, so worktree-relative paths must match the same
# root-anchored impl/test globs as main-repo paths.
# ---------------------------------------------------------------------------

@test "blocks pbi-ut-author reading worktree-prefixed impl path" {
  run bash -c "echo '$(payload pbi-ut-author Read .scrum/worktrees/pbi-001/src/auth.py)' | $HOOK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "blocks pbi-implementer writing worktree-prefixed test path" {
  run bash -c "echo '$(payload pbi-implementer Write .scrum/worktrees/pbi-001/tests/test_auth.py)' | $HOOK"
  [ "$status" -eq 2 ]
}

@test "allows pbi-ut-author writing worktree-prefixed test path" {
  run bash -c "echo '$(payload pbi-ut-author Write .scrum/worktrees/pbi-001/tests/test_auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows pbi-implementer writing worktree-prefixed src path" {
  run bash -c "echo '$(payload pbi-implementer Write .scrum/worktrees/pbi-001/src/auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks pbi-ut-author reading absolute worktree-prefixed impl path" {
  run bash -c "echo '$(payload pbi-ut-author Read "$PWD/.scrum/worktrees/pbi-001/src/auth.py")' | $HOOK"
  [ "$status" -eq 2 ]
}
