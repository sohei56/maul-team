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

# alloc_next_id <file> <jq_array_path> <prefix> <pad_width>
# Compute the next monotonic id for an append-only store: scan
# <jq_array_path>[].id for `<prefix>NNN`, take max(N)+1 (0 when the array is
# empty or absent → the first id is <prefix> padded to 1), zero-pad the result
# to <pad_width> (a minimum width: values needing more digits grow naturally,
# e.g. imp-9999 → imp-10000), and echo `<prefix><padded>`. <prefix> must include its
# trailing hyphen (e.g. "imp-", "dec-"). Fails E_SCHEMA (via lib/errors.sh) if
# the computed value is non-numeric, signalling a corrupt store.
#
# <jq_array_path> is a trusted literal (e.g. ".entries", ".decisions") and is
# interpolated into the jq program, mirroring atomic_write's expr handling.
alloc_next_id() {
  local file="$1" arr="$2" prefix="$3" pad="$4"
  local base="${prefix%-}"
  local next_n
  next_n="$(jq -r --arg p "$base" '
    ('"$arr"' // [])
    | map(.id | capture("^" + $p + "-(?<n>[0-9]+)$").n | tonumber)
    | (max // 0) + 1
  ' "$file" 2>/dev/null || true)"
  case "$next_n" in
    ''|*[!0-9]*) fail E_SCHEMA "could not compute next id from $file" ;;
  esac
  printf '%s%0*d' "$prefix" "$pad" "$next_n"
}

# backlog_status_enum <schema_path>
# Print the PBI status enum from the deployed backlog.schema.json, one value
# per line. The schema is the sole authority on valid statuses — wrappers must
# derive their allow-lists from it rather than hardcode a parallel copy (a
# hardcoded list drifts when the enum grows; see the `cancelled` incident in
# docs/MIGRATION-scrum-state-tools.md). Calls `fail` from lib/errors.sh —
# ensure errors.sh is sourced first.
backlog_status_enum() {
  local schema="$1"
  [ -f "$schema" ] || fail E_FILE_MISSING "$schema"
  local out
  out="$(jq -r '.properties.items.items.properties.status.enum[]' "$schema" 2>/dev/null || true)"
  [ -n "$out" ] || fail E_SCHEMA "cannot read status enum from $(basename "$schema")"
  printf '%s\n' "$out"
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
