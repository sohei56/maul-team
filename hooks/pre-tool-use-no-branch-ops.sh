#!/usr/bin/env bash
# hooks/pre-tool-use-no-branch-ops.sh — block free-form git branch / merge / push / rebase
# from the Bash tool. Allows .scrum/scripts/* wrappers (which encapsulate the workflow).
# Receives Claude Code tool invocation JSON on stdin.
set -euo pipefail

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[ "$TOOL" = "Bash" ] || exit 0  # non-Bash tools: not our concern

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[ -n "$CMD" ] || exit 0

# Allow if the command (after leading whitespace) starts with a wrapper invocation.
case "${CMD#"${CMD%%[![:space:]]*}"}" in
  .scrum/scripts/*) exit 0 ;;
esac

# Patterns: any of these in the command is a hard block.
# We match on word-boundaries to avoid false positives ("git status" should pass).
block() {
  printf '[no-branch-ops] BLOCKED: %s. Use .scrum/scripts/* wrappers instead.\n' "$1" >&2
  exit 2
}

if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+checkout[[:space:]]+-b\b'; then
  block "git checkout -b"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+switch[[:space:]]+-c\b'; then
  block "git switch -c"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+branch[[:space:]]+[A-Za-z0-9._/-]+($|[[:space:];|&])'; then
  # `git branch <name>` (creates). Listing forms (`git branch`, `git branch -a`, `git branch --list`) pass.
  block "git branch <new-name>"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+merge\b'; then
  block "git merge"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+push\b'; then
  block "git push"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+rebase\b'; then
  block "git rebase"
fi

exit 0
