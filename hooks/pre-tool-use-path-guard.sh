#!/usr/bin/env bash
# pre-tool-use-path-guard.sh — PreToolUse hook
# Enforces path-level constraints on PBI pipeline sub-agents:
#   - pbi-ut-author: cannot Read/Write/Edit/MultiEdit impl paths; no Bash
#   - pbi-implementer: cannot Write/Edit/MultiEdit test paths; no Bash
#   - product-owner: Write/Edit/MultiEdit allowed only under
#     docs/product/** and .scrum/po/** (Bash is NOT blocked — the PO
#     needs to launch the app for acceptance verification)
# Reads payload (JSON) from stdin: {agent_name, tool_name, tool_input.file_path}
# Reads .scrum/config.json for path_guard.impl_globs and test_globs.
# Exit 2 + stderr message → blocks tool. Exit 0 → allow.
# Missing config or unknown agent → allow (fail-open for non-target agents).

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

CONFIG=".scrum/config.json"

# Read entire payload from stdin into a variable
payload="$(cat)"
agent="$(printf '%s' "$payload" | jq -r '.agent_name // ""')"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')"

# Fail-open if no agent or non-target agent
if [ -z "$agent" ]; then
  exit 0
fi
case "$agent" in
  pbi-ut-author|pbi-implementer|product-owner) ;;
  *) exit 0 ;;
esac

# Bash is too broad to preserve the intended path sandbox for restricted
# code-writing agents. Block it outright for pbi-ut-author /
# pbi-implementer rather than trying to parse arbitrary commands.
# product-owner is exempt: the PO must launch the app and run
# verification commands during acceptance.
if [ "$tool" = "Bash" ]; then
  case "$agent" in
    pbi-ut-author|pbi-implementer)
      hook_block "path-guard" "$agent cannot use Bash" "Use Read/Write/Edit/MultiEdit only on your permitted paths."
      ;;
  esac
fi

# Path-based checks below require file_path.
[ -n "$path" ] || exit 0

# Normalize path to a root-anchored relative form: strip $PWD/, collapse /./,
# and strip a leading .scrum/worktrees/<pbi>/ prefix so worktree-relative paths
# match the same root-anchored impl/test globs (see lib/validate.sh).
rel="$(project_rel_path "$path")"

# Glob match helper using bash pattern matching
matches_any_glob() {
  local target="$1"
  shift
  local g
  for g in "$@"; do
    # shellcheck disable=SC2254
    case "$target" in
      $g) return 0 ;;
    esac
  done
  return 1
}

# product-owner path restriction is a hard rule independent of
# .scrum/config.json. Evaluate it before the config-driven impl/test
# glob checks so a missing config does not fail-open the PO sandbox.
case "$agent" in
  product-owner)
    case "$tool" in
      Write|Edit|MultiEdit)
        if ! matches_any_glob "$rel" 'docs/product/**' '.scrum/po/**'; then
          hook_block "path-guard" "product-owner cannot $tool $rel (outside PO sandbox)" "PO writes are limited to docs/product/** and .scrum/po/**."
        fi
        ;;
    esac
    exit 0
    ;;
esac

# Remaining agents (pbi-ut-author, pbi-implementer) are gated by the
# config-driven impl/test globs. Fail-open if config missing.
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Read config globs into arrays. Bash 3.2 (macOS default) has no `mapfile`/
# `readarray`, and under `set -euo pipefail` calling them would abort the hook
# on the impl/test path-blocking branch (fail-open). Use a portable read loop.
impl_globs=()
while IFS= read -r _line; do
  [ -n "$_line" ] && impl_globs+=("$_line")
done < <(jq -r '.path_guard.impl_globs[]?' "$CONFIG")
test_globs=()
while IFS= read -r _line; do
  [ -n "$_line" ] && test_globs+=("$_line")
done < <(jq -r '.path_guard.test_globs[]?' "$CONFIG")

case "$agent" in
  pbi-ut-author)
    case "$tool" in
      Read|Write|Edit|MultiEdit)
        # ${#arr[@]} is safe under `set -u` even for an empty array; guard the
        # "${arr[@]}" expansion which would otherwise abort in Bash 3.2.
        if [ "${#impl_globs[@]}" -gt 0 ] && matches_any_glob "$rel" "${impl_globs[@]}"; then
          hook_block "path-guard" "pbi-ut-author cannot $tool $rel (impl path)" "UT must remain black-box; do not access impl files."
        fi
        ;;
    esac
    ;;
  pbi-implementer)
    case "$tool" in
      Write|Edit|MultiEdit)
        if [ "${#test_globs[@]}" -gt 0 ] && matches_any_glob "$rel" "${test_globs[@]}"; then
          hook_block "path-guard" "pbi-implementer cannot $tool $rel (test path)" "Implementer cannot modify tests; UT author owns test paths."
        fi
        ;;
    esac
    ;;
esac

exit 0
