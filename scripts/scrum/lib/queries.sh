#!/usr/bin/env bash
# scripts/scrum/lib/queries.sh — read-only helpers for .scrum/ state.
# Sourced by scripts/scrum/*.sh that need to read backlog/sprint state.
# `get_pbi_status` and `pbi_in_backlog` are pure (no error-exit) and can be
# sourced standalone. The PBI-worktree helpers below call `fail` from
# lib/errors.sh — ensure errors.sh is sourced before invoking them.

if [ "${_SCRUM_QUERIES_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi
_SCRUM_QUERIES_SH_LOADED=1

# get_pbi_status <pbi_id> [backlog_path] [default]
# Read .items[] | select(.id==id) | .status from backlog.json. Prints the
# status, or `default` (empty by default) when the file is missing or no
# matching item exists.
#
# Mirrors hooks/lib/validate.sh::get_pbi_status_from_backlog (identical
# jq body; only the default arg differs). The two libs live in separate
# trees (scripts/scrum/lib vs hooks/lib) and are not cross-sourced to
# avoid a circular dep — keep the jq filter in sync if either changes.
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

# read_pbi_worktree_state <pbi_id>
# Read .scrum/pbi/<pbi-id>/state.json and populate the globals
# `PBI_WT`, `PBI_BRANCH`, `PBI_BASE_SHA`. Fails (via lib/errors.sh::fail)
# if state.json is missing, the worktree directory does not exist, or
# `.branch` is unset. `.base_sha` may be empty — the caller checks if
# they need it.
read_pbi_worktree_state() {
  local pbi_id="$1"
  local state=".scrum/pbi/$pbi_id/state.json"
  [ -f "$state" ] || fail E_FILE_MISSING "$state"
  # shellcheck disable=SC2034  # consumed by callers after this returns
  PBI_WT="$(jq -r '.worktree // ""' "$state")"
  # shellcheck disable=SC2034
  PBI_BRANCH="$(jq -r '.branch // ""' "$state")"
  # shellcheck disable=SC2034
  PBI_BASE_SHA="$(jq -r '.base_sha // ""' "$state")"
  [ -n "$PBI_WT" ] && [ -d "$PBI_WT" ] || fail E_FILE_MISSING "PBI worktree missing: $PBI_WT"
  [ -n "$PBI_BRANCH" ] || fail E_INVALID_ARG "state.branch unset for $pbi_id"
}

# assert_pbi_worktree_branch <worktree_path> <expected_branch>
# Verify that the worktree's current branch matches the expected branch.
assert_pbi_worktree_branch() {
  local wt="$1" expected="$2"
  local cur
  cur="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  if [ "$cur" != "$expected" ]; then
    fail E_INVALID_ARG "worktree on wrong branch: have=$cur expected=$expected"
  fi
}
