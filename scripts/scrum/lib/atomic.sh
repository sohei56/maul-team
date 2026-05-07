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
SCRUM_LOCK_DIR=".scrum/.locks"

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
  # Insert pid+epoch *before* the extension so the tmp file keeps its .json suffix
  # (some validators, e.g. ajv-cli, require .json or treat the path as a module).
  local dir_part base_part name_part ext_part
  dir_part="$(dirname "$path")"
  base_part="$(basename "$path")"
  name_part="${base_part%.*}"
  ext_part="${base_part##*.}"
  local tmp_uniq="$$.${RANDOM}"
  local tmp
  if [ "$name_part" = "$ext_part" ]; then
    # No extension — append a uniquifier directly.
    tmp="${path}.tmp.${tmp_uniq}"
  else
    tmp="${dir_part}/${name_part}.tmp.${tmp_uniq}.${ext_part}"
  fi
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

_iso_utc_now() {
  # Mirrors hooks/lib/validate.sh::get_timestamp (authoritative). Kept inline to
  # avoid a circular dep between scripts/scrum/lib and hooks/lib.
  date -u +"%Y-%m-%dT%H:%M:%SZ"
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
