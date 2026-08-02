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
  # Failure reason is recorded in the default log (<output>.log).
  grep -q "codex-invoke: FAIL reason=missing" out.md.log
}

@test "codex_review_or_fallback writes verdict via --output-last-message and logs the transcript" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # Stub emulating `codex exec`: records the first positional arg (to
  # prove the subcommand is `exec`) and the --output-last-message value
  # (to prove the flag is passed with an ABSOLUTE path), writes the
  # verdict there, and emits transcript chatter on stdout/stderr that
  # the helper must capture into the log file.
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0-stub"; exit 0; }
echo "$1" > "$PWD/subcommand.txt"
last=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && last="$a"
  prev="$a"
done
echo "$last" > "$PWD/last-message-arg.txt"
echo "## Review: stub" > "$last"
echo "stdout chatter"
echo "stderr chatter" >&2
echo "tokens used: 42"
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
  # Relative output path was absolutized before reaching codex.
  [ "$(cat last-message-arg.txt)" = "$TEST_TMP/out.md" ]
  # Verdict contains ONLY the last message — no transcript noise.
  ! grep -q "chatter" out.md
  # The log captured both stdout and stderr chatter plus token usage.
  grep -q "stdout chatter" out.md.log
  grep -q "stderr chatter" out.md.log
  grep -q "tokens used: 42" out.md.log
}

@test "codex_review_or_fallback honors an explicit log_file argument" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0-stub"; exit 0; }
last=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && last="$a"
  prev="$a"
done
echo "## Review: stub" > "$last"
echo "stdout chatter"
exit 0
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md codex-r1.log
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 0 ]
  [ -s out.md ]
  grep -q "stdout chatter" codex-r1.log
  [ ! -e out.md.log ]
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
  grep -q "codex-invoke: FAIL reason=timeout" out.md.log
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
  grep -q "codex-invoke: FAIL reason=probe_failed" out.md.log
}

@test "codex_review_or_fallback returns 1 when codex produces empty output" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # Exit 0 without writing the --output-last-message file: the
  # untrusted-version-manager-shim class of failure.
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0-stub"; exit 0; }
exit 0
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 1 ]
  grep -q "codex-invoke: FAIL reason=empty_output" out.md.log
}

@test "codex_review_or_fallback returns 1 with rc detail when codex exits nonzero" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  cat > fake-codex.sh <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0-stub"; exit 0; }
echo "auth error: not logged in" >&2
exit 3
EOF
  chmod +x fake-codex.sh
  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  echo "instructions" > instr.md
  run codex_review_or_fallback instr.md out.md
  unset CODEX_CMD_OVERRIDE
  [ "$status" -eq 1 ]
  grep -q "codex-invoke: FAIL reason=nonzero rc=3" out.md.log
  # The stderr diagnostic that used to be discarded is preserved.
  grep -q "auth error: not logged in" out.md.log
}
