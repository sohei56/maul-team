#!/usr/bin/env bash
# validate.sh — Shared helpers for hooks: JSON validation and logging
# Sourced by hooks that parse .scrum/ state files.

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_VALIDATE_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_VALIDATE_SH_LOADED=1

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
# Path normalization (shared by the PreToolUse guards)
# ---------------------------------------------------------------------------
# These are the single source of truth for how the guard hooks reduce a
# tool-supplied path to a canonical form before glob-matching. Threat model is
# an honest agent: we normalize trivial forms (./, $PWD/, absolute, /./, and a
# .scrum/worktrees/<pbi>/ symlink prefix), not adversarial obfuscation
# (eval, $(...) substitutions, ../ traversals into PWD).

# Normalize a path against $PWD: make absolute, collapse '/./' segments.
normalize_path() {
  local p="$1"
  [ "${p:0:1}" = "/" ] || p="$PWD/$p"
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

# Reduce a tool-supplied path to a root-anchored relative path suitable for
# matching against project-root globs. Steps: (1) normalize to absolute +
# collapse /./  (2) strip $PWD/ back to relative  (3) strip a leading
# .scrum/worktrees/<pbi>/ prefix. Paths outside $PWD stay absolute (step 2 is a
# no-op) and are left untouched by step 3.
project_rel_path() {
  local p
  p="$(normalize_path "$1")"
  p="${p#"$PWD"/}"
  strip_worktree_prefix "$p"
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

  ensure_scrum_dir

  local ts
  ts="$(get_timestamp)"

  printf '%s [%s] %s: %s\n' "$ts" "$level" "$hook_name" "$message" >> "$HOOK_LOG_FILE"

  # Trim log to max lines (keep newest)
  if [ -f "$HOOK_LOG_FILE" ]; then
    local line_count
    line_count="$(wc -l < "$HOOK_LOG_FILE" | tr -d ' ')"
    if [ "$line_count" -gt "$HOOK_LOG_MAX_LINES" ]; then
      # $$.${RANDOM}: same collision hardening as the sibling tmp writers.
      local tmp_log="${HOOK_LOG_FILE}.tmp.$$.${RANDOM}"
      tail -n "$HOOK_LOG_MAX_LINES" "$HOOK_LOG_FILE" > "$tmp_log" && mv "$tmp_log" "$HOOK_LOG_FILE"
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
