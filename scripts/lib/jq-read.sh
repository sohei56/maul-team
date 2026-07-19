#!/usr/bin/env bash
# scripts/lib/jq-read.sh — shared config-scalar reader for the two watchdog
# daemons (scripts/autonomous/watchdog.sh and scripts/stall-watchdog.sh).
#
# Both daemons run in-place from the framework repo (scrum-start.sh launches
# them via $SCRIPT_DIR/scripts/...), so this lib always travels with them —
# there is no deployed copy that lacks scripts/lib/. Extracting the reader here
# lets the two daemons share one implementation instead of duplicating it.
#
# Bash 3.2 compatible. shellcheck clean.

# Guard against double-sourcing.
# shellcheck disable=SC2317
if [ "${_JQ_READ_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_JQ_READ_SH_LOADED=1

# jq_cfg_or <file> <jq_path> <default>
# Reads a scalar from a JSON <file> at <jq_path> with fall-through-to-<default>
# on missing file / invalid JSON / missing key / null value. NO type
# validation — callers that need numeric / enum guarantees must validate the
# returned string themselves.
jq_cfg_or() {
  local file="$1" path="$2" default="$3" val
  if [ ! -f "$file" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! jq empty "$file" >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  val="$(jq -r "$path // empty" "$file" 2>/dev/null || true)"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$val"
}

# jq_cfg_uint_or <file> <jq_path> <default>
# Like jq_cfg_or, but additionally validates the scalar is an unsigned
# integer (digits only; "0" is accepted) and falls back to <default>
# otherwise — the "positive-integer config fallback" idiom the daemons used
# to define locally. Note: rejects negatives (unlike
# hooks/lib/autonomy.sh::autonomy_config_int, a different process family).
jq_cfg_uint_or() {
  local v
  v="$(jq_cfg_or "$1" "$2" "$3")"
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$3" ;;
    *) printf '%s\n' "$v" ;;
  esac
}
