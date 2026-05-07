#!/usr/bin/env bats

setup() {
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/status-gate-pbi-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/design hooks
  echo '{"phase":"pbi_pipeline_active"}' > .scrum/state.json
  echo '# catalog' > docs/design/catalog.md
  echo '{"enabled":[]}' > docs/design/catalog-config.json
  cp -r "${BATS_TEST_DIRNAME}/../../hooks/lib" hooks/lib
  cp "${BATS_TEST_DIRNAME}/../../hooks/status-gate.sh" hooks/status-gate.sh
  HOOK="$PWD/hooks/status-gate.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

payload() {
  local agent="$1" tool="$2" path="$3"
  jq -n --arg a "$agent" --arg t "$tool" --arg p "$path" \
    '{agent_name: $a, tool_name: $t, tool_input: {file_path: $p}}'
}

@test "pbi_pipeline_active phase allows pbi-designer Write to .scrum/pbi/" {
  run bash -c "echo '$(payload pbi-designer Write .scrum/pbi/pbi-001/design/design.md)' | $HOOK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "allow"'
}

@test "pbi_pipeline_active phase allows pbi-implementer Write to src/" {
  run bash -c "echo '$(payload pbi-implementer Write src/auth.py)' | $HOOK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "allow"'
}

@test "pbi_pipeline_active phase allows pbi-designer Write to docs/design/specs/" {
  run bash -c "echo '$(payload pbi-designer Write docs/design/specs/api/auth.md)' | $HOOK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "allow"'
}

@test "pbi_pipeline_active phase denies non-pbi-designer Write to docs/design/specs/" {
  run bash -c "echo '$(payload pbi-implementer Write docs/design/specs/api/auth.md)' | $HOOK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "deny"'
}
