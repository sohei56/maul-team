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

@test "blocks pbi-ut-author from multi-editing impl path" {
  run bash -c "echo '$(payload pbi-ut-author MultiEdit src/auth.py)' | $HOOK"
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

@test "blocks pbi-implementer from multi-editing test path" {
  run bash -c "echo '$(payload pbi-implementer MultiEdit tests/test_auth.py)' | $HOOK"
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
