#!/usr/bin/env bash
# hooks/pre-tool-use-no-branch-ops.sh — block free-form git branch / merge / push / rebase
# from the Bash tool. Allows .scrum/scripts/* wrappers (which encapsulate the workflow).
# Receives Claude Code tool invocation JSON on stdin.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[ "$TOOL" = "Bash" ] || exit 0  # non-Bash tools: not our concern

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[ -n "$CMD" ] || exit 0

# Allow if the command (after leading whitespace) starts with a wrapper invocation.
case "${CMD#"${CMD%%[![:space:]]*}"}" in
  .scrum/scripts/*) exit 0 ;;
esac

strip_git_global_options() {
  local rest="$1"
  while :; do
    case "$rest" in
      git[[:space:]]-C[[:space:]]*)
        rest="${rest#git }"
        rest="${rest#-C }"
        rest="${rest#* }"
        rest="git ${rest#"${rest%%[![:space:]]*}"}"
        ;;
      git[[:space:]]--git-dir=* )
        rest="git ${rest#git --git-dir=* }"
        ;;
      git[[:space:]]--work-tree=* )
        rest="git ${rest#git --work-tree=* }"
        ;;
      git[[:space:]]--namespace=* )
        rest="git ${rest#git --namespace=* }"
        ;;
      git[[:space:]]-c[[:space:]]*)
        rest="${rest#git }"
        rest="${rest#-c }"
        rest="${rest#* }"
        rest="git ${rest#"${rest%%[![:space:]]*}"}"
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s' "$rest"
}

CANON_CMD="$(strip_git_global_options "${CMD#"${CMD%%[![:space:]]*}"}")"

# Patterns: any of these in the command is a hard block.
# We match on word-boundaries to avoid false positives ("git status" should pass).
block() { hook_block "no-branch-ops" "$1" "Use .scrum/scripts/* wrappers instead."; }

if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+checkout[[:space:]]+-b\b'; then
  block "git checkout -b"
fi
if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+switch[[:space:]]+-c\b'; then
  block "git switch -c"
fi
if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+branch[[:space:]]+[A-Za-z0-9_][A-Za-z0-9._/-]*($|[[:space:];|&])'; then
  # `git branch <name>` (creates). Listing/management flags (`git branch`,
  # `git branch -a`, `git branch -d <name>`, `git branch --list`) start with
  # `-` after the whitespace and pass through.
  block "git branch <new-name>"
fi
if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+merge\b'; then
  block "git merge"
fi
if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+push\b'; then
  block "git push"
fi
if echo "$CANON_CMD" | grep -Eq '^git[[:space:]]+rebase\b'; then
  block "git rebase"
fi

exit 0
