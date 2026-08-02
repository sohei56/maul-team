#!/usr/bin/env bash
# codex-invoke.sh — shared Codex CLI invocation helper.
# Sourced by codex-* reviewer agents (codex-design-reviewer,
# codex-impl-reviewer, codex-ut-reviewer) AND by the PBI pipeline
# conductor as a spawn-time preflight (codex_is_available).
#
# Usage — sourced as `scripts/lib/codex-invoke.sh` in this repo, as
# `.scrum/scripts/lib/codex-invoke.sh` in deployed projects (only
# `.scrum` is symlinked into a PBI worktree, where agents source it):
#   source .scrum/scripts/lib/codex-invoke.sh
#   codex_review_or_fallback <instructions_file> <output_file> [log_file]
#   codex_is_available && echo "codex present"
#
# codex_review_or_fallback runs `codex exec` against the CURRENT working
# directory (callers cd into the PBI worktree first — there is no
# workdir argument). Instructions are fed on stdin; the verdict is
# written by codex itself via `--output-last-message` (final agent
# message only), so transcript noise can never pollute the verdict.
# The full transcript (stdout + stderr, including codex's trailing
# token-usage line) is captured to <log_file> — default
# <output_file>.log — for post-hoc diagnosis; historically stderr was
# discarded and every failure class collapsed into a bare exit 1,
# which made "why did this Sprint silently fall back to Claude
# reviews?" undiagnosable after the fact.
#
# On failure the log gains a final line
#   codex-invoke: FAIL reason=<reason>
# and the same line (plus the log path) is echoed to the caller's
# stderr so the fallback review's Summary can cite the reason.
# Reason taxonomy:
#   missing      codex not on PATH
#   probe_failed present but the `--version` probe failed (broken
#                install / PATH shim — exit-127 class)
#   timeout      wall-clock budget exceeded (exit 124/137)
#   nonzero rc=N codex exited N (auth failure, bad flag, crash …)
#   empty_output exit 0 but the verdict file is missing or empty
#                (e.g. an untrusted version-manager shim that exits 0
#                without ever running codex)
#
# Returns:
#   codex_review_or_fallback: 0 on success with a non-empty verdict
#     file; 1 on any failure class above. Exit 1 is the caller's
#     signal to fall back to a Claude review — the reason line in the
#     log / on stderr says why.
#   codex_is_available:       0 when codex present AND executable,
#     1 otherwise. Presence alone (`command -v`) is not enough: a
#     broken install / PATH shim passes `command -v` yet exits 127 at
#     invocation time, silently degrading every review to the Claude
#     fallback (observed for a full Sprint in a target project). The
#     preflight therefore also runs a cheap `--version` probe.
#
# Environment:
#   CODEX_CMD_OVERRIDE   path to a stub binary (testing).
#   CODEX_TIMEOUT_SECS   wall-clock budget for the codex call
#                        (default 300). Enforced via `timeout` or
#                        `gtimeout` when available; if neither binary
#                        exists (e.g. stock macOS) the call runs
#                        unbounded and a one-line WARN is printed to
#                        stderr.

codex_is_available() {
  local cmd="${CODEX_CMD_OVERRIDE:-codex}"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  # Executability probe: catches exit-127-class failures (broken shim,
  # arch mismatch, dangling symlink) that `command -v` cannot see.
  # Normalize any probe failure to 1 per the documented contract.
  "$cmd" --version >/dev/null 2>&1 || return 1
}

# Internal: record a failure reason in the log and on the caller's
# stderr, then let the caller return 1.
_codex_invoke_fail() {
  local log=$1 reason=$2
  echo "codex-invoke: FAIL reason=$reason" >> "$log" 2>/dev/null || true
  echo "codex-invoke: FAIL reason=$reason (log: $log)" >&2
}

codex_review_or_fallback() {
  local instructions=$1
  local output=$2
  local log="${3:-$2.log}"
  local cmd="${CODEX_CMD_OVERRIDE:-codex}"
  local timeout_secs="${CODEX_TIMEOUT_SECS:-300}"

  # --output-last-message must be ABSOLUTE: codex resolves it against
  # its own cwd, and a relative path can strand the verdict elsewhere.
  # The log path is absolutized too so the stderr reason line stays
  # meaningful after the caller cd-s away.
  case "$output" in /*) : ;; *) output="$PWD/$output" ;; esac
  case "$log" in /*) : ;; *) log="$PWD/$log" ;; esac

  # Availability check, split (instead of calling codex_is_available)
  # so the recorded reason distinguishes "not installed" from
  # "installed but broken".
  if ! command -v "$cmd" >/dev/null 2>&1; then
    _codex_invoke_fail "$log" "missing"
    return 1
  fi
  if ! "$cmd" --version >/dev/null 2>&1; then
    _codex_invoke_fail "$log" "probe_failed"
    return 1
  fi

  # Pick a portable timeout runner. `timeout` (GNU coreutils) and
  # `gtimeout` (Homebrew coreutils) both exit 124 on timeout, 137 on
  # SIGKILL — either maps to the timeout reason below. Stock macOS
  # ships neither, so degrade to an unbounded run with a single WARN.
  #
  # The timeout prefix is applied via an explicit branch, NOT a
  # word-split `$runner` string: this file is `source`d from agent
  # Bash-tool sessions whose interactive shell may be zsh, and zsh
  # does not word-split unquoted expansions — `$runner` would be
  # passed as the single word "timeout 300", exec would exit 127, and
  # every review would silently degrade to the Claude fallback
  # (observed recurring across Sprints in a target project).
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  else
    echo "codex-invoke: WARN no timeout binary (timeout/gtimeout) found; running codex unbounded" >&2
  fi

  local rc=0
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$timeout_secs" "$cmd" exec --sandbox read-only --skip-git-repo-check \
      --output-last-message "$output" - \
      < "$instructions" > "$log" 2>&1 || rc=$?
  else
    "$cmd" exec --sandbox read-only --skip-git-repo-check \
      --output-last-message "$output" - \
      < "$instructions" > "$log" 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    _codex_invoke_fail "$log" "timeout"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    _codex_invoke_fail "$log" "nonzero rc=$rc"
    return 1
  fi

  if [ ! -s "$output" ]; then
    _codex_invoke_fail "$log" "empty_output"
    return 1
  fi
  return 0
}
