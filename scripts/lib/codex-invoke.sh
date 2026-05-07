#!/usr/bin/env bash
# codex-invoke.sh — shared Codex CLI invocation helper.
# Sourced by codex-* reviewer agents (codex-design-reviewer,
# codex-impl-reviewer, codex-ut-reviewer).
#
# Usage:
#   source scripts/lib/codex-invoke.sh
#   codex_review_or_fallback <instructions_file> <output_file>
# Returns:
#   0 on success (output_file populated by Codex)
#   1 when Codex unavailable (caller should fall back to Claude review)
#
# Honors CODEX_CMD_OVERRIDE for testing (path to a stub binary).

codex_review_or_fallback() {
  local instructions=$1
  local output=$2
  local cmd="${CODEX_CMD_OVERRIDE:-codex}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi

  "$cmd" review --uncommitted --ephemeral \
    --instructions "$instructions" \
    -o "$output" 2>&1 || return 1

  [ -s "$output" ] || return 1
  return 0
}
