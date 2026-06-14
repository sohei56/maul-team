#!/usr/bin/env bash
# codex-invoke.sh — shared Codex CLI invocation helper.
# Sourced by codex-* reviewer agents (codex-design-reviewer,
# codex-impl-reviewer, codex-ut-reviewer) AND by the PBI pipeline
# conductor as a spawn-time preflight (codex_is_available).
#
# Usage:
#   source scripts/lib/codex-invoke.sh
#   codex_review_or_fallback <instructions_file> <output_file>
#   codex_is_available && echo "codex present"
#
# codex_review_or_fallback runs `codex exec` against the CURRENT working
# directory (callers cd into the PBI worktree first — there is no
# workdir argument). Instructions are fed on stdin; the verdict is read
# from stdout into <output_file>; codex's stderr (a harmless
# "could not create PATH aliases" warning plus progress chatter) is
# discarded so it cannot pollute the verdict.
#
# Returns:
#   codex_review_or_fallback: 0 on success with non-empty output;
#     1 when codex is unavailable, exits nonzero, times out, or
#     produces empty output. Exit 1 is the caller's signal to fall
#     back to a Claude review.
#   codex_is_available:       0 when codex present, 1 when absent.
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
  command -v "$cmd" >/dev/null 2>&1
}

codex_review_or_fallback() {
  local instructions=$1
  local output=$2
  local cmd="${CODEX_CMD_OVERRIDE:-codex}"
  local timeout_secs="${CODEX_TIMEOUT_SECS:-300}"

  if ! codex_is_available; then
    return 1
  fi

  # Pick a portable timeout runner. `timeout` (GNU coreutils) and
  # `gtimeout` (Homebrew coreutils) both exit 124 on timeout, 137 on
  # SIGKILL — either maps to nonzero below. Stock macOS ships neither,
  # so degrade to an unbounded run with a single WARN.
  local runner=""
  if command -v timeout >/dev/null 2>&1; then
    runner="timeout $timeout_secs"
  elif command -v gtimeout >/dev/null 2>&1; then
    runner="gtimeout $timeout_secs"
  else
    echo "codex-invoke: WARN no timeout binary (timeout/gtimeout) found; running codex unbounded" >&2
  fi

  # Intentional word-split of $runner (the "<bin> <secs>" prefix, or
  # empty when no timeout binary is available).
  # shellcheck disable=SC2086
  $runner "$cmd" exec --sandbox read-only --skip-git-repo-check - \
    < "$instructions" > "$output" 2>/dev/null || return 1

  [ -s "$output" ] || return 1
  return 0
}
