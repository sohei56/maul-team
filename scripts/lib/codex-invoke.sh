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

  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$timeout_secs" "$cmd" exec --sandbox read-only --skip-git-repo-check - \
      < "$instructions" > "$output" 2>/dev/null || return 1
  else
    "$cmd" exec --sandbox read-only --skip-git-repo-check - \
      < "$instructions" > "$output" 2>/dev/null || return 1
  fi

  [ -s "$output" ] || return 1
  return 0
}
