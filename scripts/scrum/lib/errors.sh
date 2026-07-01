#!/usr/bin/env bash
# scripts/scrum/lib/errors.sh — fixed exit codes for scrum-state tools.
# Sourced by scripts/scrum/*.sh.

if [ "${_SCRUM_ERRORS_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # `|| true` is reachable when `return` fails (script not sourced)
  return 0 2>/dev/null || true
fi
_SCRUM_ERRORS_SH_LOADED=1

# Exit codes — exported as readonly for callers that source this file.
# shellcheck disable=SC2034  # constants are consumed by sourcing scripts/tests
readonly E_OK=0
# shellcheck disable=SC2034
readonly E_INVALID_ARG=64
# shellcheck disable=SC2034
readonly E_SCHEMA=65
# shellcheck disable=SC2034
readonly E_LOCK_TIMEOUT=66
# shellcheck disable=SC2034
readonly E_FILE_MISSING=67
# shellcheck disable=SC2034
readonly E_NO_VALIDATOR=68

fail() {
  local code_name="$1"; shift
  local msg="$*"
  local code
  case "$code_name" in
    E_INVALID_ARG)  code=64 ;;
    E_SCHEMA)       code=65 ;;
    E_LOCK_TIMEOUT) code=66 ;;
    E_FILE_MISSING) code=67 ;;
    E_NO_VALIDATOR) code=68 ;;
    *)              code=1 ;;
  esac
  printf '[scrum-tool] %s: %s\n' "$code_name" "$msg" >&2
  exit "$code"
}

# assert_hex_sha <label> <value>
# Validates a 7..40 char lowercase hex string. Fails E_INVALID_ARG with the
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
