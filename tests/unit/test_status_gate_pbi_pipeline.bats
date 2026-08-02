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

# --- Blocking contract -------------------------------------------------------
# status-gate.sh denies via hook_block: stderr + exit 2. It emits NO stdout
# decision object. Asserting exit status here (rather than a stdout `.decision`
# field) is the point: the previous `{"decision":"deny"}` + exit 0 form failed
# Claude Code's schema and let the write through, and a test reading the
# script's own stdout could never catch that.

assert_allowed() {
  [ "$status" -eq 0 ]
  # No stdout decision object — a bare exit 0 leaves the normal permission
  # flow untouched (an explicit "approve" would bypass the user's prompt).
  [ -z "$output" ]
}

assert_denied() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"$1"* ]]
}

@test "pbi_pipeline_active phase allows pbi-designer Write to .scrum/pbi/" {
  run bash -c "echo '$(payload pbi-designer Write .scrum/pbi/pbi-001/design/design.md)' | $HOOK"
  assert_allowed
}

@test "pbi_pipeline_active phase allows pbi-implementer Write to src/" {
  run bash -c "echo '$(payload pbi-implementer Write src/auth.py)' | $HOOK"
  assert_allowed
}

@test "pbi_pipeline_active phase allows pbi-designer Write to docs/design/specs/" {
  run bash -c "echo '$(payload pbi-designer Write docs/design/specs/api/auth.md)' | $HOOK"
  assert_allowed
}

@test "pbi_pipeline_active phase denies non-pbi-designer Write to docs/design/specs/" {
  run bash -c "echo '$(payload pbi-implementer Write docs/design/specs/api/auth.md)' | $HOOK"
  assert_denied "Only pbi-designer may write specs"
}

# --- Worktree-prefix normalization (RC#12 / T1-9) ---
# PBI work runs in .scrum/worktrees/<pbi-id>/; a worktree-relative spec path
# must be denied to a non-designer just like the main-repo form.

@test "pbi_pipeline_active phase denies non-pbi-designer Write to worktree-prefixed docs/design/specs/" {
  run bash -c "echo '$(payload pbi-implementer Write .scrum/worktrees/pbi-001/docs/design/specs/api/auth.md)' | $HOOK"
  assert_denied "Only pbi-designer may write specs"
}

@test "pbi_pipeline_active phase allows pbi-designer Write to worktree-prefixed docs/design/specs/" {
  run bash -c "echo '$(payload pbi-designer Write .scrum/worktrees/pbi-001/docs/design/specs/api/auth.md)' | $HOOK"
  assert_allowed
}

# --- Regression guard for the inert-gate bug --------------------------------

@test "status-gate emits no top-level stdout decision object (regression: inert gate)" {
  run bash -c "echo '$(payload pbi-implementer Write docs/design/specs/api/auth.md)' | $HOOK"
  # The old form printed {"decision":"deny"} on stdout and exited 0. Claude
  # Code's top-level decision enum is ["approve","block"], so that payload was
  # discarded and the write proceeded. Nothing may reintroduce it.
  [ "$status" -eq 2 ]
  run bash -c "echo '$(payload pbi-implementer Write docs/design/specs/api/auth.md)' | $HOOK 2>/dev/null"
  [ -z "$output" ]
}
