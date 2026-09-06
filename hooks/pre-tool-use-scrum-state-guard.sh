#!/usr/bin/env bash
# pre-tool-use-scrum-state-guard.sh — PreToolUse hook (v2).
# Blocks agent edits to .scrum/**/*.json that bypass the SSOT wrappers.
# Permitted writers live at .scrum/scripts/* in deployed projects (and at
# scripts/scrum/* inside the framework source tree for dogfooding).
#
# v2 hardening (vs v1):
#   1. File-path checks normalize a './' prefix, a '$PWD/' prefix and absolute
#      paths to one canonical form (v1 only matched the bare 'foo' relative
#      form).
#   2. Bash check no longer short-circuits on a wrapper substring match.
#      Legitimate wrapper invocations (e.g. '.scrum/scripts/foo.sh args')
#      do not match the block patterns below, so they pass naturally.
#      Removing the early-exit prevents agents from bypassing the guard by
#      sneaking the wrapper string into a comment or unrelated argument
#      while a raw write also exists in the same command.
#
# v3 hardening (Issue #93 (1)): the judgement is anchored on the RESOLVED
# PROJECT ROOT, never on the process working directory. A hook inherits the
# agent's cwd, which is routinely a package subdirectory or a per-PBI worktree;
# a $PWD-anchored pattern then failed to match a write to the real SSOT and
# exited 0, so protection was absent — and absent invisibly. Root resolution
# order and the path-normalization rule live in lib/validate.sh
# (resolve_project_root, hook_anchor_init, project_rel_path).
#
# PATTERN POLICY — FROZEN (Issue #93 (2), decision A):
#   The Write/Edit `file_path` checks are this guard's real protection:
#   they are structural and cannot be spelled around. The Bash branch's
#   command-text patterns are a guardrail against honest mistakes, NOT a
#   sandbox against obfuscation — text-scanning a shell command diverges
#   (every closed hole opens a larger one, and each hardening pass
#   over-blocks legitimate commands, e.g. a heredoc that quotes the
#   pattern). The Bash pattern set below is therefore FROZEN: adding,
#   widening or narrowing one is a design decision, not a hardening PR.
#   Same scope rule as the other shipped PreToolUse guards — see
#   CLAUDE.md § Git workflow. The count is pinned by
#   tests/lint/state-guard-pattern-freeze.bats.
#
# Stdin payload: JSON {tool_name, cwd, tool_input.{file_path,command,...}, ...}.
# Exit 2 = block (with stderr message). Exit 0 = allow.
#
# Fail policy:
#   FAIL-OPEN, narrowly: a malformed/absent payload, an unknown tool, or a
#   payload carrying no path or command at all — there is nothing to judge, and
#   breaking unrelated tool calls buys nothing.
#   FAIL-CLOSED, always: a payload that DOES carry something to judge while the
#   project root cannot be resolved. An unjudgeable write is not thereby a
#   harmless write, so the guard blocks (exit 2) instead of waving it through.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

block() { hook_block "scrum-guard" "$1" "Use .scrum/scripts/* instead. See docs/MIGRATION-scrum-state-tools.md."; }

# Fail closed: the payload carries something to judge but the project root is
# unknown, so no path judgement is trustworthy. Same block shape (stderr +
# exit 2) as every other deny here.
fail_closed() {
  hook_block "scrum-guard" \
    "cannot resolve project root; refusing to judge the write" \
    "Set CLAUDE_PROJECT_DIR to the project root, or install the hook under it."
}

# Resolve HOOK_PROJECT_ROOT / HOOK_CWD from the payload, or fail closed.
# Idempotent: the Bash branch calls it once per destination batch.
require_anchor() {
  [ -n "${HOOK_PROJECT_ROOT:-}" ] && return 0
  hook_anchor_init "$payload" || fail_closed
}

# project_rel_path / project_rel_candidates / strip_worktree_prefix are provided
# by lib/validate.sh, which owns the normalization rule. Both candidate readings
# of a relative path are judged (agent-cwd-relative and root-relative) so a
# subdirectory cwd can neither hide an SSOT write nor invent one.

# A .scrum/**/*.json path that is an agent-authored review/metric ARTIFACT,
# not wrapper-managed SSOT state. These have NO .scrum/scripts/* wrapper and
# are written directly by design — the SM persists cross-review outputs and
# the PBI pipeline emits coverage/test-results/AC-map JSON. The guard exists
# to force SSOT state (state/sprint/backlog/pbi state.json) through wrappers;
# it must not catch these artifact paths. No SSOT file lives under these
# directories, so the carve-out cannot expose state to a raw write.
# Takes an ALREADY root-relative path (one candidate), not a raw tool path:
# exemption is decided per candidate so an exempt reading of one candidate
# cannot excuse a protected sibling reading of another.
is_exempt_artifact() {
  case "$1" in
    .scrum/reviews/*.json)        return 0 ;;
    .scrum/pbi/*/metrics/*.json)  return 0 ;;
    .scrum/pbi/*/ut/*.json)       return 0 ;;
  esac
  return 1
}

# True when a root-relative candidate names wrapper-managed SSOT state.
# Bash glob `*` matches '/', so `.scrum/*.json` covers nested paths such as
# .scrum/pbi/pbi-001/state.json. A candidate outside the project root stayed
# absolute during normalization and therefore matches nothing here.
is_guarded_ssot() {
  case "$1" in
    .scrum/*.json) ! is_exempt_artifact "$1" ;;
    *) return 1 ;;
  esac
}

# Block when ANY candidate reading of <path> is non-exempt SSOT state.
# Prints the offending root-relative path via `block` (exits 2).
block_if_ssot() {
  local path="$1" reason="$2" cand
  # `if`, not `a && b`: a false condition would make the loop (and therefore
  # this function) exit non-zero under `set -e`, turning an ALLOW into a hook
  # error. An `if` with no else always ends 0.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if is_guarded_ssot "$cand"; then
      block "$reason$cand"
    fi
  done <<EOF
$(project_rel_candidates "$path")
EOF
}

# Block if ANY write destination in $1 (newline-separated paths) is a non-exempt
# SSOT .scrum json. A command can contain multiple write targets
# (e.g. one redirect to an exempt artifact and one to backlog.json); validating
# each destination individually prevents an exempt artifact path from masking a
# sibling SSOT write — a single-capture check (BASH_REMATCH) would only see the
# first match and let the rest through. `block` exits 2, so the first non-exempt
# destination short-circuits.
block_unless_all_exempt() {
  local dests="$1" reason="$2" d
  require_anchor
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    block_if_ssot "$d" "$reason: "
  done <<EOF
$dests
EOF
}

# Read payload defensively
payload="$(read_hook_payload)"
[ -n "$payload" ] || exit 0

# Extract tool_name; bail to allow if missing
tool="$(payload_get "$payload" '.tool_name')"
[ -n "$tool" ] || exit 0

case "$tool" in
  Write|Edit)
    file="$(payload_get "$payload" '.tool_input.file_path')"
    [ -n "$file" ] || exit 0
    require_anchor
    block_if_ssot "$file" "$tool "
    ;;
  Bash)
    cmd="$(payload_get "$payload" '.tool_input.command')"
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
