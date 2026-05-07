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

# Ensure .scrum directory exists
ensure_scrum_dir() {
  if [ ! -d ".scrum" ]; then
    mkdir -p ".scrum"
  fi
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
    echo "[validate] WARNING: $file does not exist." >&2
    return 1
  fi

  if ! jq empty "$file" 2>/dev/null; then
    echo "[validate] WARNING: $file contains invalid JSON." >&2
    log_hook "validate" "ERROR" "$file contains invalid JSON"
    return 1
  fi

  local field
  for field in "$@"; do
    if ! jq -e "has(\"$field\")" "$file" >/dev/null 2>&1; then
      echo "[validate] WARNING: $file missing required field '$field'." >&2
      log_hook "validate" "WARN" "$file missing required field '$field'"
      return 1
    fi
  done

  return 0
}
