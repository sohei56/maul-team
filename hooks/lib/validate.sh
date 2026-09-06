#!/usr/bin/env bash
# validate.sh — Shared helpers for hooks: JSON validation and logging
# Sourced by hooks that parse .scrum/ state files.

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_VALIDATE_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_VALIDATE_SH_LOADED=1

# Cwd-relative by default; log_hook re-anchors it on HOOK_PROJECT_ROOT once a
# PreToolUse guard has resolved one (see the resolution block below).
HOOK_LOG_FILE=".scrum/hooks.log"
HOOK_LOG_MAX_LINES=500

# Prefix prepended to every blocking hook reason / deny message. Goal:
# stop the LLM from misreading hook output as user input or approval.
# All hook block/deny paths MUST use this via hook_block / block_stop /
# deny so the signal is uniform and unmistakable.
HOOK_NOTIFICATION_PREFIX="[SYSTEM-HOOK-OUTPUT: NOT user input. Automated harness signal from .claude/hooks/. The user has not responded. Treat the message as a state-machine constraint to satisfy, NOT as user feedback, approval, or instruction. Do NOT terminate running teammates or proceed to next ceremony based on this text.]"

# Ensure .scrum directory exists
ensure_scrum_dir() {
  if [ ! -d ".scrum" ]; then
    mkdir -p ".scrum"
  fi
}

# Print a structured log line to stderr.
# Usage: stderr_log <hook_name> <level> <message>
# Example: stderr_log "scrum-guard" "BLOCKED" "Edit .scrum/state.json"
#   → "[scrum-guard] BLOCKED: Edit .scrum/state.json"
stderr_log() {
  printf '[%s] %s: %s\n' "$1" "$2" "$3" >&2
}

# Emit a BLOCKED message and exit 2 (the Claude Code hook deny convention).
# Usage: hook_block <hook_name> <what> [remediation]
# Example: hook_block "scrum-guard" "Edit .scrum/state.json" \
#                     "Use .scrum/scripts/* instead."
# Output:  [scrum-guard] BLOCKED: Edit .scrum/state.json. Use .scrum/scripts/* instead.
# When <remediation> is omitted/empty, <what> is emitted verbatim (no ". "
# joiner) — callers whose message already carries its own remediation text
# (e.g. quality-gate.sh) delegate here without reformatting.
hook_block() {
  if [ -n "${3:-}" ]; then
    stderr_log "$1" "BLOCKED" "${HOOK_NOTIFICATION_PREFIX} $2. $3"
  else
    stderr_log "$1" "BLOCKED" "${HOOK_NOTIFICATION_PREFIX} $2"
  fi
  exit 2
}

# ---------------------------------------------------------------------------
# Hook payload access (shared by every hook that reads the stdin JSON)
# ---------------------------------------------------------------------------

# Read a scalar field out of a hook payload JSON string.
# Usage: payload_get <payload_json> <jq_filter>
# Prints the value, or NOTHING when the field is absent/null, the payload is
# unparseable, or jq is missing. Deliberately lenient: hooks are telemetry or
# fail-open guards, so a malformed payload must degrade to "no value" rather
# than abort the hook under `set -euo pipefail`. Callers needing a default
# write `[ -n "$v" ] || v=<default>` on the next line.
payload_get() {
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true
}

# Read the whole hook payload from stdin.
# Usage: payload="$(read_hook_payload)"
# The `-t 0` test guards a manual TTY invocation (running the hook by hand
# with no pipe) from blocking forever on `cat`; under the harness stdin is
# always a pipe. Empty output means "nothing on stdin" — every caller must
# treat that as a no-op.
read_hook_payload() {
  if [ -t 0 ]; then
    return 0
  fi
  cat 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Project-root resolution + path normalization (shared by the PreToolUse guards)
# ---------------------------------------------------------------------------
# A hook process inherits the AGENT's working directory, which is routinely NOT
# the project root: a package subdirectory, or a per-PBI worktree under
# .scrum/worktrees/<pbi>/. Anchoring a path judgement on $PWD therefore
# mis-judges silently and exits 0 — the guard looks healthy while protecting
# nothing (Issue #93 (1)). Every guard anchors on the RESOLVED PROJECT ROOT
# instead, and fails closed when the root cannot be resolved.
#
# Threat model is unchanged: an honest agent. We normalize trivial forms (./,
# absolute, /./, and a .scrum/worktrees/<pbi>/ symlink prefix), not adversarial
# obfuscation (eval, $(...) substitutions, ../ traversals).

# Resolve the project root. Prints it on stdout; returns 1 when it cannot.
# Order:
#   1. $CLAUDE_PROJECT_DIR when set and a directory. Claude Code exports it for
#      every hook process, and BOTH registration templates spell the hook
#      command as "$CLAUDE_PROJECT_DIR/..." (framework: hooks/, deployed
#      target: .claude/hooks/) — so an unset value means the hook could not
#      have been launched at all. This is the primary anchor.
#   2. Walk up from the hook's own INSTALLED directory looking for a project
#      marker, in this order per directory: .scrum/, .claude/settings.json,
#      .git (a file inside a worktree, a directory in a normal clone). Nearest
#      ancestor wins. Covers a hand-invocation and a relocated/copied install
#      under either layout.
#   3. Neither → return 1. Callers MUST fail closed; see the guards.
# The result is cached in HOOK_PROJECT_ROOT_CACHE: a guard resolves once per
# write destination and this walks the filesystem.
resolve_project_root() {
  if [ -n "${HOOK_PROJECT_ROOT_CACHE:-}" ]; then
    printf '%s' "$HOOK_PROJECT_ROOT_CACHE"
    return 0
  fi
  local d resolved=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    resolved="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd)" || resolved=""
  fi
  if [ -z "$resolved" ]; then
    d="${HOOK_DIR:-}"
    if [ -z "$d" ]; then
      d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || d=""
    fi
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if [ -d "$d/.scrum" ] || [ -f "$d/.claude/settings.json" ] || [ -e "$d/.git" ]; then
        resolved="$d"
        break
      fi
      d="$(dirname "$d")"
    done
  fi
  [ -n "$resolved" ] || return 1
  HOOK_PROJECT_ROOT_CACHE="$resolved"
  printf '%s' "$resolved"
}

# Establish the two anchors every guard judges against, from the hook payload:
#   HOOK_PROJECT_ROOT — the resolved project root (see resolve_project_root)
#   HOOK_CWD          — the AGENT's working directory: payload `.cwd`, falling
#                       back to $PWD. That is the base the tool itself resolves
#                       a relative path against, so the guard must use the same
#                       one or it judges a different file than the one written.
# Returns non-zero ONLY when the root cannot be resolved. Callers MUST then
# fail closed (exit 2) rather than allow — a write the guard cannot judge is
# not thereby a harmless write.
# Usage: hook_anchor_init "$payload" || <fail closed>
hook_anchor_init() {
  local payload="${1:-}"
  HOOK_CWD="$(payload_get "$payload" '.cwd')"
  [ -n "$HOOK_CWD" ] || HOOK_CWD="$PWD"
  while [ "${#HOOK_CWD}" -gt 1 ] && [ "${HOOK_CWD%/}" != "$HOOK_CWD" ]; do
    HOOK_CWD="${HOOK_CWD%/}"
  done
  HOOK_PROJECT_ROOT="$(resolve_project_root)" || return 1
  [ -n "$HOOK_PROJECT_ROOT" ] || return 1
}

# Normalize a path to absolute form against <base> (default: HOOK_CWD, itself
# defaulting to $PWD), collapsing '/./' segments.
normalize_path() {
  local p="$1" base="${2:-${HOOK_CWD:-$PWD}}"
  [ "${p:0:1}" = "/" ] || p="$base/$p"
  while [[ "$p" == */./* ]]; do
    p="${p/\/.\//\/}"
  done
  printf '%s' "$p"
}

# Strip a leading ".scrum/worktrees/<segment>/" prefix (exactly one segment =
# the PBI id) from a RELATIVE path, so a worktree-relative path is matched
# against the same root-anchored globs (src/**, tests/**, docs/design/specs/*,
# .scrum/*.json) as a main-repo path. POSIX-safe (no Bash-4 features).
#   .scrum/worktrees/pbi-001/tests/x.py           -> tests/x.py
#   .scrum/worktrees/pbi-001/.scrum/backlog.json  -> .scrum/backlog.json
#     (each worktree has .scrum -> ../../../.scrum, so this refers to the real
#      shared SSOT and must STILL match the guard patterns after stripping)
strip_worktree_prefix() {
  local p="$1" rest
  case "$p" in
    .scrum/worktrees/*/*)
      rest="${p#.scrum/worktrees/}"   # <segment>/<rest...>
      printf '%s' "${rest#*/}"        # drop the single <segment>/ prefix
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

# THE NORMALIZATION RULE — single source of truth for every guard:
#   1. An ABSOLUTE tool path is taken as-is.
#   2. A RELATIVE tool path is resolved against the AGENT'S CWD (HOOK_CWD),
#      NOT against the project root, because that is what the tool will do.
#   3. The absolute result is then expressed relative to the PROJECT ROOT, and
#      a leading .scrum/worktrees/<pbi>/ prefix is stripped (that prefix is a
#      symlink back into the root's own .scrum tree). Anything outside the root
#      stays absolute and therefore matches no root-anchored glob.
# Worked cases. cwd = <root>/packages/web, tool path <root>/.scrum/backlog.json:
# step 1 keeps it absolute, step 3 yields `.scrum/backlog.json` — this is the
# write that used to pass. cwd = <root>/.scrum/worktrees/pbi-001, tool path
# `.scrum/backlog.json`: step 2 yields
# <root>/.scrum/worktrees/pbi-001/.scrum/backlog.json and step 3 yields
# `.scrum/backlog.json`; the absolute spelling of the same file lands there too.
# Requires a successful hook_anchor_init.
project_rel_path() {
  local p
  p="$(normalize_path "$1")"
  p="${p#"${HOOK_PROJECT_ROOT:-$PWD}"/}"
  strip_worktree_prefix "$p"
}

# The root-anchored reading of the SAME tool path: a relative path is resolved
# against the PROJECT ROOT instead of the agent cwd. This is the second
# candidate meaning of a relative path — an agent that names `.scrum/backlog.json`
# from a subdirectory almost always means the SSOT and has its cwd wrong.
# Guards protecting a specific tree judge BOTH candidates and block when EITHER
# is protected, so the harmless reading cannot excuse the dangerous one.
# For an absolute path this returns exactly what project_rel_path returns.
project_rel_path_from_root() {
  local p
  p="$(normalize_path "$1" "${HOOK_PROJECT_ROOT:-$PWD}")"
  p="${p#"${HOOK_PROJECT_ROOT:-$PWD}"/}"
  strip_worktree_prefix "$p"
}

# Print every candidate root-relative spelling of a tool path, deduped, one per
# line: project_rel_path first, then project_rel_path_from_root when it differs.
# See project_rel_path_from_root for why both are judged.
project_rel_candidates() {
  local a b
  a="$(project_rel_path "$1")"
  b="$(project_rel_path_from_root "$1")"
  printf '%s\n' "$a"
  [ "$b" = "$a" ] || printf '%s\n' "$b"
}

# Get current ISO 8601 timestamp (works on both BSD and GNU date).
# Authoritative timestamp helper. scripts/scrum/lib/atomic.sh::_iso_utc_now
# mirrors this format; keep both in sync if format changes.
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

# Create a JSON file with a jq -n template if it does not exist.
# Usage: ensure_json_file <filepath> <jq_init_expr> [jq_args...]
ensure_json_file() {
  local filepath="$1"
  local init_expr="$2"
  shift 2
  ensure_scrum_dir
  if [ ! -f "$filepath" ]; then
    jq -n "$@" "$init_expr" > "$filepath"
  fi
}

# Read .items[] | select(.id==id) | .status from backlog.json. Returns the
# status string, or `default` (default: "unknown") when the file is missing
# or no matching item exists. Mirrors scripts/scrum/lib/queries.sh::
# get_pbi_status; intentionally duplicated to keep hooks/lib/ standalone.
# Usage: get_pbi_status_from_backlog <pbi_id> [backlog_path] [default]
get_pbi_status_from_backlog() {
  local pbi_id="$1"
  local backlog="${2:-.scrum/backlog.json}"
  local default="${3:-unknown}"
  if [ ! -f "$backlog" ]; then
    printf '%s' "$default"
    return
  fi
  local out
  out="$(jq -r --arg id "$pbi_id" --arg d "$default" \
    '.items[]? | select(.id == $id) | .status // $d' \
    "$backlog" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$out"
  fi
}

# Atomically update a JSON file in place: run `jq [jq_args...] <jq_expr>`
# against <file>, write to a temp sibling, and mv on success. On jq failure the
# temp is removed and the original is left untouched. Returns non-zero on
# failure WITHOUT exiting — callers (fail-open hooks) decide how to react. jq
# stderr is suppressed to keep hot-path hooks quiet.
#
# LOCKING: the jq read and the mv are a read-modify-write pair and MUST be
# serialized. dashboard-event.sh fires on every PostToolUse from every
# concurrently-running teammate and sub-agent, and both append_comms_message
# and append_dashboard_event route through here. Without a lock, two hooks that
# both read before either mv silently drop one event — and
# completion-gate.sh::count_in_flight_subagents derives its count from exactly
# these subagent_start/subagent_stop events, so a dropped stop inflates the
# count and produces a spurious "N subagent(s) still running — do NOT
# re-spawn". Uses the same mkdir directory-lock idiom as
# scripts/scrum/lib/atomic.sh::_acquire_lock (flock is unavailable on stock
# macOS); KEEP THE TWO IN SYNC.
#
# On lock-acquisition timeout this returns non-zero rather than blocking a
# hot-path hook: losing one dashboard event under extreme contention is
# strictly better than corrupting the file, and every caller already tolerates
# a non-zero return. A lock older than JSON_LOCK_STALE_SEC is broken so a hook
# killed mid-write cannot wedge the path permanently.
# NOTE: helpers in hooks/lib/autonomy.sh and hooks/lib/stop-gate-state.sh do NOT
# use this — those libs are sourced standalone (without validate.sh) by their
# unit tests, so they keep their own inline tmp+mv idiom.
# Usage: json_update_atomic <file> <jq_expr> [jq_args...]
JSON_LOCK_TIMEOUT_SEC="${JSON_LOCK_TIMEOUT_SEC:-2}"
JSON_LOCK_POLL_SEC="${JSON_LOCK_POLL_SEC:-0.05}"
JSON_LOCK_STALE_SEC="${JSON_LOCK_STALE_SEC:-30}"

# _json_mtime_of <path> — epoch seconds of <path>'s mtime, or 0 when unknown
# (path missing, or neither stat dialect produced a number).
#
# Each candidate is validated as a pure integer rather than the two stat
# forms being chained with `||`, because that naive chain is FATAL on Linux:
# GNU stat reads `-f` as --file-system and treats the format as a file NAME,
# so it prints a multi-line filesystem block on stdout *and* exits non-zero.
# The fallback then appends the GNU epoch to that block, and the caller's
# `$((now - mtime))` resolves the block's leading `File` as a variable —
# aborting the whole hook process under `set -u`. macOS never showed it
# because BSD stat succeeds on the first try. (Do not restore the chain to
# shorten this: tests/lint/mirror-helpers.bats greps all three trees for it.)
#
# MIRROR of scripts/scrum/lib/activity.sh::mtime_of (canonical). Duplicated
# rather than sourced because hooks/lib/ must stay standalone (see the NOTE
# above). KEEP IN SYNC — pinned by tests/lint/mirror-helpers.bats.
_json_mtime_of() {
  local p="$1" m
  [ -e "$p" ] || { printf '0\n'; return 0; }
  m="$(stat -f %m "$p" 2>/dev/null || true)"
  case "$m" in
    ''|*[!0-9]*) m="$(stat -c %Y "$p" 2>/dev/null || true)" ;;
  esac
  case "$m" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$m" ;;
  esac
}

_json_lock_is_stale() {
  local lock_dir="$1" now mtime
  now="$(date +%s 2>/dev/null)" || return 1
  mtime="$(_json_mtime_of "$lock_dir")"
  # 0 = mtime unknown → NOT stale. Fail-safe direction: leaving a live lock
  # alone costs one acquisition timeout, breaking one corrupts the file.
  [ "$mtime" -gt 0 ] || return 1
  [ "$((now - mtime))" -ge "$JSON_LOCK_STALE_SEC" ]
}

_json_acquire_lock() {
  local lock_dir="$1" max_iters i=0
  max_iters="$(awk -v t="$JSON_LOCK_TIMEOUT_SEC" -v p="$JSON_LOCK_POLL_SEC" 'BEGIN{print int(t/p)+1}')"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if _json_lock_is_stale "$lock_dir"; then
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    i=$((i + 1))
    [ "$i" -ge "$max_iters" ] && return 1
    sleep "$JSON_LOCK_POLL_SEC"
  done
}

json_update_atomic() {
  local file="$1"
  local expr="$2"
  shift 2
  local lock_dir="${file}.lock.d"
  _json_acquire_lock "$lock_dir" || return 1
  # ${RANDOM} as well as $$: matches the hardening already applied to the
  # sibling writers (autonomy.sh, stop-gate-state.sh, watchdog.sh, atomic.sh).
  local tmp="${file}.tmp.$$.${RANDOM}"
  local rc=0
  if jq "$@" "$expr" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    rc=1
  fi
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

# Append item_json to .<array_field>, trim to .<max_field> (defaulted via
# max_default), write atomically. Thin semantic wrapper over
# json_update_atomic: this function only builds the capped-append jq
# expression + args; the temp-file, atomic mv, and cleanup-on-failure
# behavior all come from json_update_atomic (so a jq failure removes the
# temp and leaves the file untouched, returning non-zero).
# Usage: append_to_json_array <filepath> <array_field> <item_json> <max_field> <max_default>
append_to_json_array() {
  local filepath="$1"
  local array_field="$2"
  local item_json="$3"
  local max_field="$4"
  local max_default="$5"
  # shellcheck disable=SC2016  # $af/$mf/$md/$item are jq variables, not shell expansion.
  json_update_atomic "$filepath" '
    .[$af] = ((.[$af] // []) + [$item]) |
    (.[$mf] // $md) as $cap |
    if (.[$af] | length) > $cap then
      .[$af] = .[$af][(.[$af] | length) - $cap:]
    else
      .
    end
  ' --argjson item "$item_json" \
    --arg af "$array_field" \
    --arg mf "$max_field" \
    --argjson md "$max_default"
}

# Log a timestamped message to .scrum/hooks.log
# Usage: log_hook <hook_name> <level> <message>
# Levels: INFO, WARN, ERROR
log_hook() {
  local hook_name="$1"
  local level="$2"
  local message="$3"

  # Anchor the log on the project root when a guard resolved one, so a deny
  # raised from a package subdirectory or a worktree appends to the project's
  # real .scrum/hooks.log instead of creating a stray .scrum/ beside the cwd the
  # hook happened to inherit. Every other hook (HOOK_PROJECT_ROOT unset) keeps
  # the cwd-relative behaviour unchanged.
  local ts log
  log="${HOOK_PROJECT_ROOT:+$HOOK_PROJECT_ROOT/}$HOOK_LOG_FILE"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  ts="$(get_timestamp)"

  printf '%s [%s] %s: %s\n' "$ts" "$level" "$hook_name" "$message" >> "$log"

  # Trim log to max lines (keep newest)
  if [ -f "$log" ]; then
    local line_count
    line_count="$(wc -l < "$log" | tr -d ' ')"
    if [ "$line_count" -gt "$HOOK_LOG_MAX_LINES" ]; then
      # $$.${RANDOM}: same collision hardening as the sibling tmp writers.
      local tmp_log="${log}.tmp.$$.${RANDOM}"
      tail -n "$HOOK_LOG_MAX_LINES" "$log" > "$tmp_log" && mv "$tmp_log" "$log"
    fi
  fi
}

# Validate that a JSON file exists, is valid JSON, and contains required fields.
# Usage: validate_json_file <file> <field1> [field2 ...]
# Returns 0 if valid, 1 if invalid (prints warning to stderr).
validate_json_file() {
  local file="$1"
  shift

  if [ ! -f "$file" ]; then
    stderr_log "validate" "WARNING" "$file does not exist."
    return 1
  fi

  if ! jq empty "$file" 2>/dev/null; then
    stderr_log "validate" "WARNING" "$file contains invalid JSON."
    log_hook "validate" "ERROR" "$file contains invalid JSON"
    return 1
  fi

  local field
  for field in "$@"; do
    if ! jq -e "has(\"$field\")" "$file" >/dev/null 2>&1; then
      stderr_log "validate" "WARNING" "$file missing required field '$field'."
      log_hook "validate" "WARN" "$file missing required field '$field'"
      return 1
    fi
  done

  return 0
}
