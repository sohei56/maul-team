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
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # Claude Code exports CLAUDE_PROJECT_DIR for every hook process (both
  # registration templates spell the hook command as "$CLAUDE_PROJECT_DIR/..."),
  # and the guard anchors every glob on it. Simulating it is what makes
  # TEST_TMP the project root here instead of this repository.
  export CLAUDE_PROJECT_DIR="$TEST_TMP"
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

# ---------------------------------------------------------------------------
# Issue #93 (1): the sandbox globs are anchored on the PROJECT ROOT, not on the
# working directory the hook process happens to inherit.
# ---------------------------------------------------------------------------

# Run the guard with a specific working directory; production sends both the
# process cwd and the payload's `.cwd`. Payload via file — stdin is never left
# open.
guard_at() {  # <cwd> <agent> <tool> <path>
  jq -nc --arg a "$2" --arg c "$1" --arg t "$3" --arg p "$4" \
    '{agent_name:$a, cwd:$c, tool_name:$t, tool_input:{file_path:$p}}' \
    > "$TEST_TMP/payload.json"
  run bash -c "cd '$1' && '$HOOK' < '$TEST_TMP/payload.json'"
}

# --- (b) cwd = a package subdirectory ---

@test "path-guard(subdir cwd): blocks pbi-ut-author reading the absolute impl path" {
  mkdir -p packages/web
  guard_at "$TEST_TMP/packages/web" pbi-ut-author Read "$TEST_TMP/src/auth.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "path-guard(subdir cwd): a relative path is judged as the file the tool will open" {
  # `src/auth.py` from packages/web denotes packages/web/src/auth.py — a
  # different file from the root's src/auth.py, and one the configured
  # `src/**` glob does not cover. So: allowed under that config...
  mkdir -p packages/web/src
  guard_at "$TEST_TMP/packages/web" pbi-ut-author Read src/auth.py
  [ "$status" -eq 0 ]

  # ...and blocked the moment the config covers it, which proves the judgement
  # really runs against the cwd-resolved path instead of quietly no-op'ing.
  jq -n '{path_guard:{impl_globs:["src/**","packages/**/src/**"],test_globs:["tests/**"]}}' \
    > "$TEST_TMP/.scrum/config.json"
  guard_at "$TEST_TMP/packages/web" pbi-ut-author Read src/auth.py
  [ "$status" -eq 2 ]
  [[ "$output" == *"packages/web/src/auth.py"* ]]
}

@test "path-guard(subdir cwd): blocks pbi-implementer writing the absolute test path" {
  mkdir -p packages/web
  guard_at "$TEST_TMP/packages/web" pbi-implementer Write "$TEST_TMP/tests/test_auth.py"
  [ "$status" -eq 2 ]
}

@test "path-guard(subdir cwd): allows pbi-ut-author to write the absolute test path" {
  mkdir -p packages/web
  guard_at "$TEST_TMP/packages/web" pbi-ut-author Write "$TEST_TMP/tests/test_auth.py"
  [ "$status" -eq 0 ]
}

@test "path-guard(subdir cwd): PO sandbox holds on the absolute docs/product path" {
  mkdir -p packages/web docs/product
  guard_at "$TEST_TMP/packages/web" product-owner Write "$TEST_TMP/docs/product/vision.md"
  [ "$status" -eq 0 ]
  guard_at "$TEST_TMP/packages/web" product-owner Write "$TEST_TMP/src/main.py"
  [ "$status" -eq 2 ]
}

# --- (c) cwd = a simulated PBI worktree (shares .scrum via a symlink) ---

setup_worktree() {
  mkdir -p "$TEST_TMP/.scrum/worktrees/pbi-001/src" \
           "$TEST_TMP/.scrum/worktrees/pbi-001/tests"
  ln -s ../../../.scrum "$TEST_TMP/.scrum/worktrees/pbi-001/.scrum"
}

@test "path-guard(worktree cwd): blocks pbi-ut-author reading the relative impl path" {
  setup_worktree
  guard_at "$TEST_TMP/.scrum/worktrees/pbi-001" pbi-ut-author Read src/auth.py
  [ "$status" -eq 2 ]
}

@test "path-guard(worktree cwd): blocks pbi-implementer writing the absolute test path" {
  setup_worktree
  guard_at "$TEST_TMP/.scrum/worktrees/pbi-001" pbi-implementer Write \
    "$TEST_TMP/.scrum/worktrees/pbi-001/tests/test_auth.py"
  [ "$status" -eq 2 ]
}

@test "path-guard(worktree cwd): config is read through the shared .scrum symlink" {
  # The config lives at <root>/.scrum/config.json; from a worktree cwd the old
  # cwd-relative read found it only by the symlink's grace. Prove the glob
  # enforcement is live by asserting a block, not just an allow.
  setup_worktree
  guard_at "$TEST_TMP/.scrum/worktrees/pbi-001" pbi-ut-author Write src/auth.py
  [ "$status" -eq 2 ]
}

@test "path-guard(worktree cwd): allows pbi-ut-author to write the relative test path" {
  setup_worktree
  guard_at "$TEST_TMP/.scrum/worktrees/pbi-001" pbi-ut-author Write tests/test_auth.py
  [ "$status" -eq 0 ]
}

# --- (d) unresolvable root → FAIL CLOSED ---

@test "path-guard(no root): fails CLOSED when the root cannot be resolved" {
  local orphan d
  orphan="$(mktemp -d /tmp/claude/path-guard-orphan.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/path-guard-orphan.XXXXXX")"
  mkdir -p "$orphan/hooks/lib"
  cp "$PROJECT_ROOT/hooks/pre-tool-use-path-guard.sh" "$orphan/hooks/"
  cp "$PROJECT_ROOT/hooks/lib/validate.sh" "$orphan/hooks/lib/"
  # The walk stops at "/" without testing it, so this only holds while the temp
  # ancestors are marker-free — asserted so a dirty environment fails loudly.
  d="$orphan/hooks"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -d "$d/.scrum" ] || [ -f "$d/.claude/settings.json" ] || [ -e "$d/.git" ] \
      && { echo "test environment is dirty: project marker at $d" >&2; return 1; }
    d="$(dirname "$d")"
  done
  jq -nc '{agent_name:"pbi-ut-author", tool_name:"Read", tool_input:{file_path:"src/auth.py"}}' \
    > "$TEST_TMP/payload.json"
  run env -u CLAUDE_PROJECT_DIR bash -c \
    "cd '$TEST_TMP' && '$orphan/hooks/pre-tool-use-path-guard.sh' < '$TEST_TMP/payload.json'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve project root; refusing to judge the write"* ]]

  # Narrow fail-open survives: a non-target agent needs no judgement.
  jq -nc '{agent_name:"other-agent", tool_name:"Read", tool_input:{file_path:"src/auth.py"}}' \
    > "$TEST_TMP/payload.json"
  run env -u CLAUDE_PROJECT_DIR bash -c \
    "cd '$TEST_TMP' && '$orphan/hooks/pre-tool-use-path-guard.sh' < '$TEST_TMP/payload.json'"
  rm -rf "$orphan"
  [ "$status" -eq 0 ]
}
