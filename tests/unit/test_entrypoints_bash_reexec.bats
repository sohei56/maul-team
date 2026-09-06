#!/usr/bin/env bats
# The documented launch command is `sh …/scrum-start.sh`. On Linux /bin/sh is
# dash, which rejects `set -o pipefail` and bash arrays, so every bash-only
# entry point must re-exec itself under bash before its first bashism, and
# internal call sites must not launch bash-only scripts through `sh`.
# Found on the first ubuntu CI run of the integration suites (2026-09-06).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ENTRYPOINTS=(scrum-start.sh scripts/setup-user.sh scripts/setup-dev.sh)
}

# Line number of the first `set -euo pipefail` and of the re-exec guard.
first_line_matching() {
  grep -n -m1 -E "$2" "$1" | cut -d: -f1
}

@test "every entry point re-execs under bash before its first bashism" {
  for f in "${ENTRYPOINTS[@]}"; do
    path="$PROJECT_ROOT/$f"
    guard="$(first_line_matching "$path" '^if \[ -z "\$\{BASH_VERSION:-\}" \]; then$')"
    reexec="$(first_line_matching "$path" '^  exec bash "\$0" "\$@"$')"
    pipefail="$(first_line_matching "$path" '^set -euo pipefail$')"
    [ -n "$guard" ] || { echo "$f: no BASH_VERSION guard"; false; }
    [ -n "$reexec" ] || { echo "$f: guard does not exec bash"; false; }
    [ -n "$pipefail" ] || { echo "$f: no set -euo pipefail (test assumption broken)"; false; }
    [ "$guard" -lt "$pipefail" ] || { echo "$f: guard (line $guard) must precede set -euo pipefail (line $pipefail)"; false; }
  done
}

@test "scrum-start.sh --help works when launched with dash (Linux /bin/sh)" {
  command -v dash >/dev/null 2>&1 || skip "dash not installed"
  run dash "$PROJECT_ROOT/scrum-start.sh" --help < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"scrum-start.sh"* ]]
}

@test "negative: a bash-only script without the guard fails under dash" {
  command -v dash >/dev/null 2>&1 || skip "dash not installed"
  cat > "$BATS_TEST_TMPDIR/unguarded.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo reached
SH
  run dash "$BATS_TEST_TMPDIR/unguarded.sh" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipefail"* ]]
  [[ "$output" != *"reached"* ]]
}

@test "no entry point or wrapper launches a bash-only script through sh" {
  # Any `sh <path>` whose target is one of this repo's bash scripts. Comments
  # and the `bash` spelling are ignored; `sh -c`/`sh -n` are not launches.
  run grep -n -E '(^|[^[:alnum:]_/.-])sh[[:space:]]+("?\$[A-Za-z_{}]+/|\.scrum/scripts/|scripts/)[^[:space:]"]*\.sh' \
    "$PROJECT_ROOT/scrum-start.sh" "$PROJECT_ROOT"/scripts/*.sh "$PROJECT_ROOT"/scripts/scrum/*.sh \
    "$PROJECT_ROOT"/scripts/autonomous/*.sh "$PROJECT_ROOT"/hooks/*.sh
  hits="$(printf '%s\n' "$output" | grep -v -E ':[[:space:]]*#' || true)"
  [ -z "$hits" ] || { echo "sh launches of bash scripts:"; echo "$hits"; false; }
}

@test "negative: the sh-launch detector flags a fixture" {
  printf '%s\n' 'sh "$SCRIPT_DIR/scripts/setup-user.sh"' '  sh .scrum/scripts/init-state.sh' 'bash "$SCRIPT_DIR/ok.sh"' '# sh scripts/commented.sh' > "$BATS_TEST_TMPDIR/fixture.sh"
  run grep -n -E '(^|[^[:alnum:]_/.-])sh[[:space:]]+("?\$[A-Za-z_{}]+/|\.scrum/scripts/|scripts/)[^[:space:]"]*\.sh' "$BATS_TEST_TMPDIR/fixture.sh"
  hits="$(printf '%s\n' "$output" | grep -v -E ':[[:space:]]*#' || true)"
  [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 2 ]
}
