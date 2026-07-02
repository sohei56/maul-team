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
# Usage: hook_block <hook_name> <what> <remediation>
# Example: hook_block "scrum-guard" "Edit .scrum/state.json" \
#                     "Use .scrum/scripts/* instead."
# Output:  [scrum-guard] BLOCKED: Edit .scrum/state.json. Use .scrum/scripts/* instead.
hook_block() {
  stderr_log "$1" "BLOCKED" "${HOOK_NOTIFICATION_PREFIX} $2. $3"
  exit 2
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

# Append item_json to .<array_field>, trim to .<max_field> (defaulted via
# max_default), write atomically.
# Usage: append_to_json_array <filepath> <array_field> <item_json> <max_field> <max_default>
append_to_json_array() {
  local filepath="$1"
  local array_field="$2"
  local item_json="$3"
  local max_field="$4"
  local max_default="$5"
  local tmp_file="${filepath}.tmp.$$"
  jq --argjson item "$item_json" \
     --arg af "$array_field" \
     --arg mf "$max_field" \
     --argjson md "$max_default" '
    .[$af] = ((.[$af] // []) + [$item]) |
    (.[$mf] // $md) as $cap |
    if (.[$af] | length) > $cap then
      .[$af] = .[$af][(.[$af] | length) - $cap:]
    else
      .
    end
  ' "$filepath" > "$tmp_file" && mv "$tmp_file" "$filepath"
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
      local tmp_log="${HOOK_LOG_FILE}.tmp.$$"
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
