#!/usr/bin/env bash
# hooks/pre-tool-use-no-branch-ops.sh — block free-form git branch / merge / push
# / rebase / worktree-add-b from the Bash tool. Allows .scrum/scripts/* wrappers
# (which encapsulate the workflow).
#
# Scope / threat model: this is a guardrail against *honest mistakes*, not a
# sandbox against a hostile agent. The command string is split on shell
# statement boundaries (&&, ||, ;, |, newlines) and each plain `git …`-leading
# segment (optionally after `git -C/-c/--git-dir/--work-tree/--namespace`
# global options) is matched against the block patterns. Segment forms that
# reach git through another program (`xargs git …`, `command git …`, `env git
# …`, subshells, eval, aliases) are intentionally out of scope — defeating a
# deliberately obfuscated command is a non-goal.
#
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

TRIMMED="${CMD#"${CMD%%[![:space:]]*}"}"

# Allowlist: a command that is *solely* a wrapper invocation (optionally via
# `bash`/`sh`, optionally `./`-prefixed) is allowed outright. A compound
# command does NOT inherit this — `.scrum/scripts/x.sh && git push` is not a
# lone wrapper call, so it falls through to per-segment scanning and the
# `git push` segment is blocked.
NL=$'\n'  # real newline (Bash 3.2 ANSI-C quoting; command-subst would strip it)
case "$CMD" in
  *'&&'*|*'||'*|*';'*|*'|'*|*"$NL"*) is_compound=1 ;;
  *) is_compound=0 ;;
esac
if [ "$is_compound" -eq 0 ] \
  && printf '%s' "$TRIMMED" | grep -Eq '^(bash |sh )?(\./)?\.scrum/scripts/[^ ]+\.sh( |$)'; then
  exit 0
fi

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

block() { hook_block "no-branch-ops" "$1" "Use .scrum/scripts/* wrappers instead."; }

# Apply the block patterns to a single canonicalized (global-options-stripped)
# command segment. Any match is a hard block (hook_block exits 2). Patterns are
# segment-anchored on `^git` — correct now that the caller feeds one statement
# segment at a time. Word boundaries avoid false positives (`git status` passes).
check_segment() {
  local seg="$1"
  if echo "$seg" | grep -Eq '^git[[:space:]]+checkout[[:space:]]+-b\b'; then
    block "git checkout -b"
  fi
  if echo "$seg" | grep -Eq '^git[[:space:]]+switch[[:space:]]+-c\b'; then
    block "git switch -c"
  fi
  if echo "$seg" | grep -Eq '^git[[:space:]]+branch[[:space:]]+[A-Za-z0-9_][A-Za-z0-9._/-]*($|[[:space:];|&])'; then
    # `git branch <name>` (creates). Listing/management flags (`git branch`,
    # `git branch -a`, `git branch -d <name>`, `git branch --list`) start with
    # `-` after the whitespace and pass through.
    block "git branch <new-name>"
  fi
  if echo "$seg" | grep -Eq '^git[[:space:]]+merge([[:space:]]|$)'; then
    # Bare `git merge` / `git merge <branch>` blocked.
    # `git merge-base` and `git mergetool` are read-only / interactive helpers
    # that share the prefix but require `-` after `merge` — those pass through.
    block "git merge"
  fi
  if echo "$seg" | grep -Eq '^git[[:space:]]+push\b'; then
    block "git push"
  fi
  if echo "$seg" | grep -Eq '^git[[:space:]]+rebase([[:space:]]|$)'; then
    # Allow recovery operations on an interrupted rebase; only branch-rewriting
    # invocations (e.g. `git rebase main`, `git rebase -i HEAD~3`) get blocked.
    if ! echo "$seg" | grep -Eq '^git[[:space:]]+rebase[[:space:]]+(--abort|--continue|--skip|--quit|--edit-todo|--show-current-patch)([[:space:]]|$)'; then
      block "git rebase"
    fi
  fi
  # `git worktree add -b <branch>` also creates a branch. The framework's
  # legitimate caller is `.scrum/scripts/create-pbi-worktree.sh`; raw agent
  # use is blocked so a stray agent cannot create arbitrary branches via the
  # worktree-add side-door. Read-only worktree forms (`git worktree list`,
  # `worktree prune`, `worktree remove`) pass through.
  if echo "$seg" | grep -Eq '^git[[:space:]]+worktree[[:space:]]+add\b.*[[:space:]]-b\b'; then
    block "git worktree add -b <branch>"
  fi
}

# Split the command on shell statement boundaries into newline-separated
# segments (Bash 3.2-safe: parameter expansion `${var//pat/repl}`, no mapfile,
# no BSD-sed `\n` replacement). Two-char operators are replaced before the
# single `|` so `||` does not leave a stray pipe.
SEGMENTS="$CMD"
SEGMENTS="${SEGMENTS//&&/$NL}"
SEGMENTS="${SEGMENTS//||/$NL}"
SEGMENTS="${SEGMENTS//;/$NL}"
SEGMENTS="${SEGMENTS//|/$NL}"

# Here-string keeps the loop in the current shell so `block`'s `exit 2`
# terminates the hook (a pipeline subshell would swallow it).
while IFS= read -r seg || [ -n "$seg" ]; do
  seg="${seg#"${seg%%[![:space:]]*}"}"   # trim leading whitespace
  [ -n "$seg" ] || continue
  check_segment "$(strip_git_global_options "$seg")"
done <<< "$SEGMENTS"

exit 0
