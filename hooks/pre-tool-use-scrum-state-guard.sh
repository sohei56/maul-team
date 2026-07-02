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

# normalize_path / strip_worktree_prefix are provided by lib/validate.sh.

# Collapse a ".scrum/worktrees/<pbi>/" symlink prefix from an ABSOLUTE path.
# A write to .scrum/worktrees/<pbi>/.scrum/backlog.json targets the real shared
# SSOT (each worktree has .scrum -> ../../../.scrum), so stripping the prefix
# makes it match the same guard / exempt patterns as a main-repo write. Only
# fires under "$PWD"/.scrum/worktrees/<seg>/…; paths elsewhere are untouched.
abs_strip_worktree() {
  local a="$1"
  case "$a" in
    "$PWD"/.scrum/worktrees/*/*)
      printf '%s' "$PWD/$(strip_worktree_prefix "${a#"$PWD"/}")"
      ;;
    *)
      printf '%s' "$a"
      ;;
  esac
}

# A .scrum/**/*.json path that is an agent-authored review/metric ARTIFACT,
# not wrapper-managed SSOT state. These have NO .scrum/scripts/* wrapper and
# are written directly by design — the SM persists cross-review outputs and
# the PBI pipeline emits coverage/test-results/AC-map JSON. The guard exists
# to force SSOT state (state/sprint/backlog/pbi state.json) through wrappers;
# it must not catch these artifact paths. No SSOT file lives under these
# directories, so the carve-out cannot expose state to a raw write.
is_exempt_artifact() {
  local p
  p="$(abs_strip_worktree "$(normalize_path "$1")")"
  case "$p" in
    "$PWD"/.scrum/reviews/*.json)        return 0 ;;
    "$PWD"/.scrum/pbi/*/metrics/*.json)  return 0 ;;
    "$PWD"/.scrum/pbi/*/ut/*.json)       return 0 ;;
  esac
  return 1
}

# Block if ANY write destination in $1 (newline-separated paths) is a non-exempt
# SSOT .scrum json. A command can contain multiple write targets
# (e.g. `... > .scrum/reviews/ok.json; ... > .scrum/backlog.json`); validating
# each destination individually prevents an exempt artifact path from masking a
# sibling SSOT write — a single-capture check (BASH_REMATCH) would only see the
# first match and let the rest through. `block` exits 2, so the first non-exempt
# destination short-circuits.
block_unless_all_exempt() {
  local dests="$1" reason="$2" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    is_exempt_artifact "$d" || block "$reason: $d"
  done <<EOF
$dests
EOF
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
    abs_file="$(abs_strip_worktree "$(normalize_path "$file")")"
    # Bash glob `*` matches '/', so the pattern covers nested paths like
    # $PWD/.scrum/pbi/pbi-001/state.json too.
    case "$abs_file" in
      "$PWD"/.scrum/*.json)
        is_exempt_artifact "$abs_file" && exit 0
        rel="${abs_file#"$PWD"/}"
        block "$tool $rel"
        ;;
    esac
    ;;
  Bash)
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] || exit 0

    # Block raw redirects/in-place edits targeting .scrum/*.json, UNLESS every
    # write destination is a non-SSOT artifact (see is_exempt_artifact —
    # review/metric outputs are written directly by design and have no wrapper).
    #
    # We extract ALL write destinations per operator (not just the first match,
    # and not every .scrum json in the command — only the write targets) so that
    # (a) an exempt artifact path cannot mask a sibling SSOT write in a compound
    # command, and (b) reading an SSOT json while writing an artifact json in the
    # same command is not over-blocked.
    sgrep() { printf '%s\n' "$cmd" | grep -oE "$1" 2>/dev/null || true; }

    # Redirect / tee / sponge: dest is the token after '>' '>>' 'tee' 'sponge'.
    #   X > .scrum/foo.json | tee .scrum/foo.json | sponge .scrum/foo.json
    redirect_dests="$(sgrep '(>>?|tee|sponge)[[:space:]]+[^[:space:]]*\.scrum/[^[:space:]]*\.json' \
      | sed -E 's/^[^[:space:]]+[[:space:]]+//')"
    [ -n "$redirect_dests" ] && block_unless_all_exempt "$redirect_dests" \
      "raw redirect to .scrum json from Bash"

    # mv/cp into .scrum/*.json — dest is the last arg (the jq-redirect-then-rename
    # second half). Assumes single-source `mv src dst` form, matching prior guard.
    mvcp_dests="$(sgrep '(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]*\.scrum/[^[:space:]]*\.json' \
      | sed -E 's/^(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+//')"
    [ -n "$mvcp_dests" ] && block_unless_all_exempt "$mvcp_dests" \
      "mv/cp into .scrum json from Bash (use .scrum/scripts/* wrapper)"

    # In-place editors (jq -i / sed -i / awk -i inplace) and truncate: the file
    # operand IS the write target. When the command carries such an editor, every
    # .scrum json token in it is a write destination.
    if [[ "$cmd" =~ jq[[:space:]]+-i ]] \
       || [[ "$cmd" =~ sed[[:space:]]+-i ]] \
       || [[ "$cmd" =~ awk[[:space:]]+-i[[:space:]]+inplace ]] \
       || [[ "$cmd" =~ truncate[[:space:]] ]]; then
      inplace_dests="$(sgrep '\.scrum/[^[:space:]]*\.json')"
      [ -n "$inplace_dests" ] && block_unless_all_exempt "$inplace_dests" \
        "in-place edit/truncate on .scrum json"
    fi

    # rm / unlink of an SSOT json: a raw delete bypasses the wrappers exactly
    # like a raw write, so it must be blocked too. When the command invokes rm
    # or unlink as a command word, treat every .scrum json token as a deletion
    # target (mirrors the in-place-editor branch above; exempt artifacts are
    # still allowed via block_unless_all_exempt). The (^|[^[:alnum:]_]) anchor
    # keeps `perform`, `confirm`, `.scrum/scripts/rollover-sprint.sh`, etc. from
    # matching — a wrapper invocation carries no bare `rm `/`unlink ` word.
    if [[ "$cmd" =~ (^|[^[:alnum:]_])rm[[:space:]] ]] \
       || [[ "$cmd" =~ (^|[^[:alnum:]_])unlink[[:space:]] ]]; then
      rm_dests="$(sgrep '\.scrum/[^[:space:]]*\.json')"
      [ -n "$rm_dests" ] && block_unless_all_exempt "$rm_dests" \
        "rm/unlink of .scrum json from Bash (use .scrum/scripts/* wrapper)"
    fi
    ;;
  *)
    : # other tools (Read, Grep, Glob, ...) allowed
    ;;
esac

exit 0
