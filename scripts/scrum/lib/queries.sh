#!/usr/bin/env bash
# scripts/scrum/lib/queries.sh — read-only helpers for .scrum/ state.
# Sourced by scripts/scrum/*.sh that need to read backlog/sprint state.
# No dependencies (no errors.sh, no atomic.sh) so it can be sourced standalone.

if [ "${_SCRUM_QUERIES_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi
_SCRUM_QUERIES_SH_LOADED=1

# get_pbi_status <pbi_id> [backlog_path] [default]
# Read .items[] | select(.id==id) | .status from backlog.json. Prints the
# status, or `default` (empty by default) when the file is missing or no
# matching item exists.
get_pbi_status() {
  local pbi_id="$1"
  local backlog="${2:-.scrum/backlog.json}"
  local default="${3:-}"
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

# pbi_in_backlog <pbi_id> [backlog_path]
# Returns 0 if the PBI id appears in backlog.items, 1 otherwise.
pbi_in_backlog() {
  local pbi_id="$1"
  local backlog="${2:-.scrum/backlog.json}"
  [ -f "$backlog" ] || return 1
  jq -e --arg id "$pbi_id" \
    '.items | map(select(.id == $id)) | length > 0' \
    "$backlog" >/dev/null 2>&1
}
