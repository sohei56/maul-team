#!/usr/bin/env bash
# scripts/scrum/lib/atomic.sh — directory-lock + tmp+mv + schema validation helper.
# Sourced by scripts/scrum/*.sh. Requires lib/errors.sh sourced first.

if [ "${_SCRUM_ATOMIC_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # `|| true` is reachable when `return` fails (script not sourced)
  return 0 2>/dev/null || true
fi
_SCRUM_ATOMIC_SH_LOADED=1

LOCK_TIMEOUT_SEC="${SCRUM_LOCK_TIMEOUT:-10}"
LOCK_POLL_SEC="${SCRUM_LOCK_POLL:-0.05}"
# Unified lock root (shared with catalog locks and merge-pbi's merge.lock.d).
# Name families cannot collide: wrapper locks are `<file>.json.lock.d`,
# the merge lock is `merge.lock.d`, catalog locks are `catalog-*.md.lock.d`.
SCRUM_LOCK_DIR=".scrum/locks"

# Resolve directory holding this script (used to locate sibling check-validator.sh)
_SCRUM_ATOMIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# atomic_write <path> <jq_expr> <schema_path>
# Applies <jq_expr> to <path>, validates against <schema_path>, writes atomically under a directory lock.
# Sets `.updated_at = <now>` only if the *original* file already had that property.
atomic_write() {
  local path="$1" expr="$2" schema="$3"
  [ -f "$path" ]   || fail E_FILE_MISSING "$path"
  [ -f "$schema" ] || fail E_FILE_MISSING "$schema"

  mkdir -p "$SCRUM_LOCK_DIR"
  local lock_dir
  lock_dir="$SCRUM_LOCK_DIR/$(basename "$path").lock.d"
  local tmp; tmp="$(_make_tmp_path "$path")"
  local now; now="$(_iso_utc_now)"

  _acquire_lock "$lock_dir"
  # shellcheck disable=SC2064
  trap "rmdir '$lock_dir' 2>/dev/null || true; rm -f '$tmp' 2>/dev/null || true" RETURN

  # Detect whether the file already has updated_at; if so, set it to now after applying expr.
  local touch_expr=""
  if jq -e 'has("updated_at")' "$path" >/dev/null 2>&1; then
    touch_expr=" | .updated_at = \$now"
  fi

  if ! jq --arg now "$now" "$expr$touch_expr" "$path" > "$tmp"; then
    rm -f "$tmp"
    rmdir "$lock_dir" 2>/dev/null || true
    trap - RETURN
    fail E_INVALID_ARG "jq expression failed: $expr"
  fi

  local err
  if ! err="$(_validate_against_schema "$tmp" "$schema" 2>&1)"; then
    rm -f "$tmp"
    rmdir "$lock_dir" 2>/dev/null || true
    trap - RETURN
    fail E_SCHEMA "result violates $(basename "$schema"): $err"
  fi

  mv "$tmp" "$path"
  rmdir "$lock_dir" 2>/dev/null || true
  trap - RETURN
}

# atomic_create <path> <schema> <jq_expr> [jq_args...]
# Seed a fresh state file: render <jq_expr> via `jq -n [jq_args...]`, validate
# the result against <schema>, then mv it into place. On validation failure the
# tmp file is removed and it fails E_SCHEMA with `init produced invalid
# <basename>: <err>`. Unlike atomic_write this takes no directory lock (initial
# creation is not a concurrent mutation) and does not touch updated_at — the
# caller's jq_expr seeds every field. Caller owns the already-exists / mkdir
# guards.
atomic_create() {
  local path="$1" schema="$2" expr="$3"; shift 3
  local tmp; tmp="$(_make_tmp_path "$path")"
  jq -n "$@" "$expr" > "$tmp"
  local err
  if ! err="$(_validate_against_schema "$tmp" "$schema" 2>&1)"; then
    rm -f "$tmp"
    fail E_SCHEMA "init produced invalid $(basename "$path"): $err"
  fi
  mv "$tmp" "$path"
}

_iso_utc_now() {
  # Mirrors hooks/lib/validate.sh::get_timestamp (authoritative). Kept inline to
  # avoid a circular dep between scripts/scrum/lib and hooks/lib.
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# json_lines_to_array
# Read newline-delimited items from stdin and emit a compact JSON array of
# strings (one element per line; special chars JSON-escaped). Empty stdin
# yields []. Bash 3.2-safe: a single two-stage jq pipeline, no shell arrays.
# Callers with CSV input pipe through `tr ',' '\n'` first, and must keep their
# own explicit empty-array guard — an empty bash array expands to one blank
# line under `set -u`, which would otherwise yield [""] rather than [].
json_lines_to_array() {
  jq -R . | jq -cs .
}

# _make_tmp_path <target_path>
# Build a uniquified tmp path that preserves the target's extension. ajv-cli
# treats path-without-.json as a module ref, so callers about to validate must
# use this to avoid spurious "module not found" failures.
_make_tmp_path() {
  local path="$1"
  local dir_part base_part name_part ext_part tmp_uniq
  dir_part="$(dirname "$path")"
  base_part="$(basename "$path")"
  name_part="${base_part%.*}"
  ext_part="${base_part##*.}"
  tmp_uniq="$$.${RANDOM}"
  if [ "$name_part" = "$ext_part" ]; then
    printf '%s\n' "${path}.tmp.${tmp_uniq}"
  else
    printf '%s\n' "${dir_part}/${name_part}.tmp.${tmp_uniq}.${ext_part}"
  fi
}

_acquire_lock() {
  local lock_dir="$1"
  local max_iters
  # POSIX awk for fractional poll
  max_iters="$(awk -v t="$LOCK_TIMEOUT_SEC" -v p="$LOCK_POLL_SEC" 'BEGIN{print int(t/p)+1}')"
  local i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$max_iters" ]; then
      fail E_LOCK_TIMEOUT "$lock_dir held > ${LOCK_TIMEOUT_SEC}s"
    fi
    sleep "$LOCK_POLL_SEC"
  done
}

# _validate_against_schema <json_path> <schema_path>
# Returns 0 on valid, non-zero on invalid. Validator stderr is left intact so
# callers can capture it via `err="$(_validate_against_schema ... 2>&1)"`;
# stdout is suppressed because successful validators chatter ("X valid").
_validate_against_schema() {
  local json="$1" schema="$2"
  local runner
  runner="$("$_SCRUM_ATOMIC_DIR/check-validator.sh")" || return 1
  case "$runner" in
    ajv)
      # --strict=false: tolerate unknown formats (e.g. "date-time") and unconstrained
      # tuples instead of erroring on schema load. We still get full pattern/enum/required
      # validation for the cases this codebase actually exercises.
      npx --yes ajv-cli validate --strict=false -s "$schema" -d "$json" >/dev/null
      ;;
    check-jsonschema)
      check-jsonschema --schemafile "$schema" "$json" >/dev/null
      ;;
    jsonschema-cli)
      jsonschema --instance "$json" "$schema" >/dev/null
      ;;
    python)
      python3 -c "
import json, sys, jsonschema
schema = json.load(open('$schema'))
data = json.load(open('$json'))
try:
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as exc:
    print(f'validation error: {exc.message}', file=sys.stderr)
    sys.exit(1)
"
      ;;
    *)
      return 1
      ;;
  esac
}
