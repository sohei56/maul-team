#!/usr/bin/env bash
# scripts/scrum/lib/errors.sh — fixed exit codes for scrum-state tools.
# Sourced by scripts/scrum/*.sh.

if [ "${_SCRUM_ERRORS_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # `|| true` is reachable when `return` fails (script not sourced)
  return 0 2>/dev/null || true
fi
_SCRUM_ERRORS_SH_LOADED=1

# fail <E_NAME> <message...>
# Prints `[scrum-tool] <E_NAME>: <message>` to stderr and exits with the
# fixed code mapped below. Callers pass the name as a STRING (e.g.
# `fail E_INVALID_ARG "bad status"`); this case map is the single source
# of the name → exit-code binding (documented in
# docs/MIGRATION-scrum-state-tools.md § Failure modes).
fail() {
  local code_name="$1"; shift
  local msg="$*"
  local code
  case "$code_name" in
    E_INVALID_ARG)  code=64 ;;
    E_SCHEMA)       code=65 ;;
    E_LOCK_TIMEOUT) code=66 ;;
    E_FILE_MISSING) code=67 ;;
    *)              code=1 ;;
  esac
  printf '[scrum-tool] %s: %s\n' "$code_name" "$msg" >&2
  exit "$code"
}

# assert_hex_sha <label> <value>
# Cheap sanity check on a sha argument: first char must be lowercase hex and
# length must be 7..40. NOT a full character-set validation — the schema's
# ^[0-9a-f]{7,40}$ pattern is the final gate. Fails E_INVALID_ARG with the
# label embedded in the message. Used by mark-pbi-merged.sh, mark-pbi-merge-
# failure.sh, update-pbi-state.sh.
assert_hex_sha() {
  local label="$1" value="$2"
  case "$value" in
    [0-9a-f]*) ;;
    *) fail E_INVALID_ARG "$label must be hex sha: $value" ;;
  esac
  if [ "${#value}" -lt 7 ] || [ "${#value}" -gt 40 ]; then
    fail E_INVALID_ARG "$label length must be 7..40: $value"
  fi
}

# assert_pbi_id <value> [label]
# Validates a pbi-NNN identifier. Fails E_INVALID_ARG otherwise. The optional
# label customizes the error text (defaults to "pbi-id"); pass a flag name such
# as "--parent" or "--pbi" at call sites that validate a flag argument.
assert_pbi_id() {
  local value="$1" label="${2:-pbi-id}"
  case "$value" in
    pbi-[0-9]*) ;;
    *) fail E_INVALID_ARG "bad $label: $value" ;;
  esac
}

# assert_sprint_id <value> [label]
# Validates a sprint-NNN identifier. Fails E_INVALID_ARG otherwise. The optional
# label customizes the error text (defaults to "sprint-id"); pass a flag name
# such as "--sprint" or "--id" at call sites that validate a flag argument.
# Mirrors assert_pbi_id.
assert_sprint_id() {
  local value="$1" label="${2:-sprint-id}"
  case "$value" in
    sprint-[0-9]*) ;;
    *) fail E_INVALID_ARG "bad $label: $value" ;;
  esac
}

# parse_json_string_array <label> <value>
# Parse <value> as JSON, require an array of strings, and echo the compact form
# (jq -ce) on success. On malformed JSON the wrapper fails E_INVALID_ARG
# "<label>: not valid JSON: <value>"; on wrong shape it fails "<label>: must be
# a JSON array of strings". <label> is the field name so each caller keeps its
# field-specific error text. Used by set-backlog-item-field.sh (catalog_targets,
# acceptance_criteria, design_doc_paths) and set-sprint-developer.sh (sub_agents).
parse_json_string_array() {
  local label="$1" value="$2" compact
  if ! compact="$(printf '%s' "$value" | jq -ce '.')"; then
    fail E_INVALID_ARG "$label: not valid JSON: $value"
  fi
  if ! printf '%s' "$compact" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null; then
    fail E_INVALID_ARG "$label: must be a JSON array of strings"
  fi
  printf '%s' "$compact"
}
