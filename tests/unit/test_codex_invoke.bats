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

# --- Codex model selection (-m) ---------------------------------------
# The stub at tests/fixtures/fake-codex.sh records its exec argv (one
# arg per line) in FAKE_CODEX_ARGS_FILE. Helper: print the argv line
# that follows `-m`, or nothing when `-m` is absent.
_m_value() {
  awk 'prev == "-m" { print; exit } { prev = $0 }' "$1"
}

_setup_model_stub() {
  export CODEX_CMD_OVERRIDE="${BATS_TEST_DIRNAME}/../fixtures/fake-codex.sh"
  export FAKE_CODEX_ARGS_FILE="$TEST_TMP/argv.txt"
  echo "instructions" > instr.md
}

_write_config_model() {
  # $1 = JSON value for agents.codex-reviewers.model (quoted string or null)
  mkdir -p .scrum
  printf '{"agents":{"codex-reviewers":{"provider":"codex","model":%s}}}\n' "$1" > .scrum/config.json
}

_teardown_model_stub() {
  unset CODEX_CMD_OVERRIDE FAKE_CODEX_ARGS_FILE CODEX_MODEL SCRUM_CONFIG_FILE
}

@test "codex_review_or_fallback passes -m from .scrum/config.json agents.codex-reviewers.model" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  _write_config_model '"gpt-5.6-luna"'
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  [ "$(_m_value argv.txt)" = "gpt-5.6-luna" ]
  # Argument order: exec, then -m <model>, then the fixed flags.
  [ "$(sed -n 1p argv.txt)" = "exec" ]
  [ "$(sed -n 2p argv.txt)" = "-m" ]
  [ "$(sed -n 4p argv.txt)" = "--sandbox" ]
  # Diagnostic: the resolved model is the first log line.
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=gpt-5.6-luna" ]
  # Transcript still appended after the model line.
  grep -q "tokens used: 1234" out.md.log
}

@test "codex_review_or_fallback lets CODEX_MODEL override the config model" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  _write_config_model '"gpt-5.6-luna"'
  export CODEX_MODEL="gpt-6-astra"
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  [ "$(_m_value argv.txt)" = "gpt-6-astra" ]
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=gpt-6-astra" ]
}

@test "codex_review_or_fallback passes no -m when CODEX_MODEL is set but empty" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  _write_config_model '"gpt-5.6-luna"'
  export CODEX_MODEL=""
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  ! grep -qx -- "-m" argv.txt
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=default" ]
}

@test "codex_review_or_fallback passes no -m when no config file exists" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  [ ! -e .scrum/config.json ]
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  ! grep -qx -- "-m" argv.txt
  [ "$(sed -n 1p argv.txt)" = "exec" ]
  [ "$(sed -n 2p argv.txt)" = "--sandbox" ]
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=default" ]
}

@test "codex_review_or_fallback passes no -m when the config model is null" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  _write_config_model 'null'
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  ! grep -qx -- "-m" argv.txt
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=default" ]
}

@test "codex_review_or_fallback drops an invalid CODEX_MODEL with a WARN and still reviews" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  export CODEX_MODEL="bad id"
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  # A bad value must never fail the review.
  [ "$status" -eq 0 ]
  [ -s out.md ]
  ! grep -qx -- "-m" argv.txt
  # `run` merges stderr into $output.
  [[ "$output" == *"codex-invoke: WARN ignoring invalid codex model 'bad id'"* ]]
  [ "$(head -n 1 out.md.log)" = "codex-invoke: model=default" ]
}

@test "codex_review_or_fallback drops an invalid config model (leading dash) with a WARN" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  _write_config_model '"-rf"'
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  ! grep -qx -- "-m" argv.txt
  [[ "$output" == *"codex-invoke: WARN ignoring invalid codex model '-rf'"* ]]
}

@test "codex_review_or_fallback honors SCRUM_CONFIG_FILE for the model lookup" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  mkdir -p alt
  echo '{"agents":{"codex-reviewers":{"provider":"codex","model":"gpt-5.6-luna"}}}' > alt/cfg.json
  [ ! -e .scrum/config.json ]
  export SCRUM_CONFIG_FILE="$TEST_TMP/alt/cfg.json"
  run codex_review_or_fallback instr.md out.md
  _teardown_model_stub
  [ "$status" -eq 0 ]
  [ "$(_m_value argv.txt)" = "gpt-5.6-luna" ]
}

@test "codex_review_or_fallback passes -m on the unbounded (no timeout binary) branch too" {
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  _setup_model_stub
  export CODEX_MODEL="gpt-6-astra"
  # Hide timeout/gtimeout so the no-timeout branches run. The stub needs
  # jq, so expose it through a shim dir on an otherwise minimal PATH.
  local PATH_BACKUP="$PATH"
  local shim="$TEST_TMP/shim"
  mkdir -p "$shim"
  ln -s "$(command -v jq)" "$shim/jq"
  export PATH="$shim:/usr/bin:/bin"
  run codex_review_or_fallback instr.md out.md
  export PATH="$PATH_BACKUP"
  _teardown_model_stub
  [ "$status" -eq 0 ]
  [ "$(_m_value argv.txt)" = "gpt-6-astra" ]
  [[ "$output" == *"WARN no timeout binary"* ]]
}
