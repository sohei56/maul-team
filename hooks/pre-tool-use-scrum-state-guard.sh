#!/usr/bin/env bash
# pre-tool-use-scrum-state-guard.sh — PreToolUse hook (v2).
# Blocks agent edits to .scrum/**/*.json that bypass the SSOT wrappers.
# Permitted writers live at .scrum/scripts/* in deployed projects (and at
# scripts/scrum/* inside the framework source tree for dogfooding).
#
# v2 hardening (vs v1):
#   1. File-path checks normalize against the absolute $PWD so that writes via
#      './' prefix, '$PWD/' prefix, or absolute paths under $PWD are caught
#      (v1 only matched the bare 'foo' relative form).
#   2. Bash check no longer short-circuits on a wrapper substring match.
#      Legitimate wrapper invocations (e.g. '.scrum/scripts/foo.sh args')
#      do not match the block patterns below, so they pass naturally.
#      Removing the early-exit prevents agents from bypassing the guard by
#      sneaking the wrapper string into a comment or unrelated argument
#      while a raw write also exists in the same command.
#
# Stdin payload: JSON {tool_name, tool_input.{file_path,command,...}, ...}.
# Exit 2 = block (with stderr message). Exit 0 = allow.
#
# Fail-open principle: any unexpected input, unknown tool, missing fields → allow.
# Better to miss enforcement than to break unrelated tool calls.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

block() { hook_block "scrum-guard" "$1" "Use .scrum/scripts/* instead. See docs/MIGRATION-scrum-state-tools.md."; }

# Normalize a path against $PWD: make absolute, collapse '/./' segments.
# Threat model is honest agent — we don't try to defeat clever obfuscation
# (eval, $(...)-substitutions, ../ traversals into PWD), just trivial forms.
normalize_path() {
  local p="$1"
  [ "${p:0:1}" = "/" ] || p="$PWD/$p"
  while [[ "$p" == */./* ]]; do
    p="${p/\/.\//\/}"
  done
  printf '%s' "$p"
}

# Read payload defensively
payload="$(cat)"
[ -n "$payload" ] || exit 0

# Extract tool_name; bail to allow if missing
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ -n "$tool" ] || exit 0

case "$tool" in
  Write|Edit|MultiEdit)
    file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    [ -n "$file" ] || exit 0
    abs_file="$(normalize_path "$file")"
    # Bash glob `*` matches '/', so the pattern covers nested paths like
    # $PWD/.scrum/pbi/pbi-001/state.json too.
    case "$abs_file" in
      "$PWD"/.scrum/*.json)
        rel="${abs_file#"$PWD"/}"
        block "$tool $rel"
        ;;
    esac
    ;;
  Bash)
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] || exit 0

    # Match a destination token containing '.scrum/<...>.json' anywhere
    # (so absolute paths and './' prefixed forms are also caught).
    DEST_RE='[^[:space:]]*\.scrum/[^[:space:]]*\.json'

    # Block raw redirects/in-place edits targeting .scrum/*.json:
    #   X > .scrum/foo.json
    #   X >> .scrum/foo.json
    #   X | tee .scrum/foo.json
    #   X | sponge .scrum/foo.json
    if [[ "$cmd" =~ (\>\>?|tee|sponge)[[:space:]]+$DEST_RE ]]; then
      block "raw redirect to .scrum json from Bash"
    fi
    if [[ "$cmd" =~ jq[[:space:]]+-i.*\.scrum/[^[:space:]]*\.json ]]; then
      block "jq -i in-place edit on .scrum json"
    fi
    if [[ "$cmd" =~ sed[[:space:]]+-i.*\.scrum/[^[:space:]]*\.json ]]; then
      block "sed -i in-place edit on .scrum json"
    fi
    if [[ "$cmd" =~ awk[[:space:]]+-i[[:space:]]+inplace.*\.scrum/[^[:space:]]*\.json ]]; then
      block "awk -i inplace edit on .scrum json"
    fi
    # mv/cp into .scrum/*.json — the second half of jq-redirect-then-rename.
    if [[ "$cmd" =~ (mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+$DEST_RE ]]; then
      block "${BASH_REMATCH[1]} into .scrum json from Bash (use .scrum/scripts/* wrapper)"
    fi
    if [[ "$cmd" =~ truncate[[:space:]]+(-s[[:space:]]+[0-9]+[[:space:]]+)?$DEST_RE ]]; then
      block "truncate on .scrum json"
    fi
    ;;
  *)
    : # other tools (Read, Grep, Glob, ...) allowed
    ;;
esac

exit 0
