#!/usr/bin/env bash
# pre-tool-use-path-guard.sh — PreToolUse hook
# Enforces path-level constraints on PBI pipeline sub-agents:
#   - pbi-ut-author: cannot Read/Write/Edit impl paths
#   - pbi-implementer: cannot Write/Edit test paths (Read allowed)
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

# Fail-open if no agent or no path or non-target agent
if [ -z "$agent" ] || [ -z "$path" ]; then
  exit 0
fi
case "$agent" in
  pbi-ut-author|pbi-implementer) ;;
  *) exit 0 ;;
esac

# Fail-open if config missing
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Normalize path: strip leading $PWD/ if absolute
rel="${path#"$PWD"/}"

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

mapfile -t impl_globs < <(jq -r '.path_guard.impl_globs[]?' "$CONFIG")
mapfile -t test_globs < <(jq -r '.path_guard.test_globs[]?' "$CONFIG")

case "$agent" in
  pbi-ut-author)
    case "$tool" in
      Read|Write|Edit)
        if matches_any_glob "$rel" "${impl_globs[@]}"; then
          hook_block "path-guard" "pbi-ut-author cannot $tool $rel (impl path)" "UT must remain black-box; do not access impl files."
        fi
        ;;
    esac
    ;;
  pbi-implementer)
    case "$tool" in
      Write|Edit)
        if matches_any_glob "$rel" "${test_globs[@]}"; then
          hook_block "path-guard" "pbi-implementer cannot $tool $rel (test path)" "Implementer cannot modify tests; UT author owns test paths."
        fi
        ;;
    esac
    ;;
esac

exit 0
