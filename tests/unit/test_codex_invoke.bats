#!/usr/bin/env bats

setup() {
  TEST_TMP="$(mktemp -d /tmp/claude/codex-test.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/codex-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  HOOK_LIB="${BATS_TEST_DIRNAME}/../../scripts/lib/codex-invoke.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "codex_review_or_fallback returns 1 when codex command missing" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  local PATH_BACKUP="$PATH"
  export PATH="/usr/bin:/bin"  # strip codex from PATH
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 1 ]
}

@test "codex_review_or_fallback returns 0 and switches to 'exec' subcommand" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # Stub emulating `codex exec`: it ignores its flags, records the
  # first positional arg to a side file (so the test can prove the
  # subcommand switched from `review` to `exec`), then echoes a stub
  # verdict to STDOUT — the function captures stdout via `> "$output"`.
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
echo "$1" > "$PWD/subcommand.txt"
echo "## Review: stub"
exit 0
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 0 ]
  [ -s out.md ]
  [ "$(cat subcommand.txt)" = "exec" ]
}

@test "codex_review_or_fallback returns 1 when codex times out" {
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no timeout/gtimeout binary available"
  fi
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
# Fast-path the availability probe; hang only on the real exec call.
[ "$1" = "--version" ] && { echo "0.0-stub"; exit 0; }
sleep 10
echo "## Review: too late"
exit 0
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  export CODEX_TIMEOUT_SECS=1
  echo "instructions" > instr.md
  local start end
  start=$(date +%s)
  run codex_review_or_fallback instr.md out.md
  end=$(date +%s)
  unset CODEX_CMD_OVERRIDE CODEX_TIMEOUT_SECS
  [ "$status" -eq 1 ]
  # Must fail-fast well under the stub's 10s sleep.
  [ "$((end - start))" -lt 5 ]
}

@test "codex_is_available returns 1 when binary present but not executable (exit 127 probe)" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # Emulates a broken install / PATH shim: `command -v` finds it, but
  # invocation fails (exit-127 class). Presence-only preflight passed
  # this and silently degraded reviews to the Claude fallback.
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  run codex_is_available
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 1 ]
}

@test "codex_review_or_fallback returns 1 when binary present but not executable" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 1 ]
}

@test "codex_review_or_fallback returns 1 when codex produces empty output" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 1 ]
}
