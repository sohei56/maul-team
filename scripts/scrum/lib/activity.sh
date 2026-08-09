#!/usr/bin/env bash
# scripts/scrum/lib/activity.sh — filesystem activity signals for PBI
# liveness: how recently was anything touched on behalf of a given PBI, and
# which PBIs are in flight right now. This is the one home for those signals
# in the scripts/ family; callers own the policy (thresholds, reporting)
# built on top of them.
#
# Two consumers reach it by two different paths:
#   - deployed to .scrum/scripts/lib/ by setup-user.sh, where the read-only
#     wrappers in .scrum/scripts/ source it;
#   - sourced in place out of this repo by scripts/stall-watchdog.sh, which
#     always runs from the framework checkout, never from a deployed copy.
#
# Sentinel rule — 0 means "unknown / never observed", never "now".
# mtime_of, max_mtime_recursive and pbi_activity_epoch all emit 0 when the
# path or the PBI artifact tree does not exist. 0 is not a timestamp:
# `now - 0` is a ~56-year idle time, and "fixing" a missing epoch by
# substituting `now` reports a dead PBI as 0s quiet and suppresses every
# probe forever. Callers MUST test for 0 explicitly and skip the PBI (or
# report it as uninitialized) before doing any idle arithmetic.
#
# Sourceable standalone: sources no other lib, does nothing at source time,
# imposes no `set -e`/`set -u` on the caller.
#
# Bash 3.2 compatible (no mapfile/readarray, no `find -print0` read loops).

if [ "${_SCRUM_ACTIVITY_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # `|| true` is reachable when `return` fails (script not sourced)
  return 0 2>/dev/null || true
fi
_SCRUM_ACTIVITY_SH_LOADED=1

# mtime_of <path> — emit epoch seconds for a file/dir mtime, portable across
# macOS (BSD stat) and Linux (GNU stat). Emits 0 if the path does not exist.
# GNU stat treats `-f %m` as "filesystem status of a file named %m" and can
# emit multi-line garbage with a nonzero exit, so each candidate output is
# validated as a pure integer before use.
mtime_of() {
  local p="$1" m
  [ -e "$p" ] || { printf '0\n'; return 0; }
  m="$(stat -f %m "$p" 2>/dev/null || true)"
  case "$m" in
    ''|*[!0-9]*) m="$(stat -c %Y "$p" 2>/dev/null || true)" ;;
  esac
  case "$m" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$m" ;;
  esac
}

# max_mtime_recursive <dir> — emit epoch of the newest mtime found anywhere
# under <dir> (inclusive). Walks files and directories so a newly-created
# subdir without files yet still counts as activity. Emits 0 on missing dir.
max_mtime_recursive() {
  local dir="$1"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  local max=0 m
  # First the dir itself
  m="$(mtime_of "$dir")"
  [ "$m" -gt "$max" ] && max="$m"
  # find -print0 not portable to bare Bash 3.2 read; the file names we walk
  # are .scrum/pbi/* — controlled internal IDs without whitespace.
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    m="$(mtime_of "$p")"
    [ "$m" -gt "$max" ] && max="$m"
  done <<EOF
$(find "$dir" -mindepth 1 2>/dev/null)
EOF
  printf '%s\n' "$max"
}

# pbi_activity_epoch <pbi_id> [scrum_dir] — newest activity epoch
# attributable to ONE PBI (scrum_dir defaults to `.scrum`, cwd-relative like
# the rest of the wrapper family):
#   - <scrum_dir>/pbi/<id>/ recursive mtime (state.json, pipeline.log,
#     reviews, metrics — small, controlled tree)
#   - the PBI worktree's last commit time (commit-pbi.sh commits)
#   - dirty/untracked file mtimes from `git status --porcelain` in the
#     worktree (live sub-agent edits between commits), capped at 200
#     entries so a pathological worktree cannot stall the poll loop
# Emits 0 when the PBI artifact dir does not exist yet (pipeline not
# initialized) — callers must skip those rather than treat 0 as "stale
# since epoch".
pbi_activity_epoch() {
  local id="$1"
  local scrum_dir="${2:-.scrum}"
  local dir="$scrum_dir/pbi/$id" wt="$scrum_dir/worktrees/$id"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  local max m
  max="$(max_mtime_recursive "$dir")"
  if [ -d "$wt" ] && command -v git >/dev/null 2>&1; then
    m="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || true)"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -gt "$max" ] && max="$m"
    # Porcelain lines are "XY path"; rename lines ("R  old -> new") yield a
    # non-existent combined path, which mtime_of maps to 0 — harmless.
    local p
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      m="$(mtime_of "$wt/$p")"
      [ "$m" -gt "$max" ] && max="$m"
    done <<EOF
$(git -C "$wt" status --porcelain 2>/dev/null | head -n 200 | cut -c4-)
EOF
  fi
  printf '%s\n' "$max"
}

# in_flight_snapshot [backlog_file] — the ONE place the in-flight PBI filter
# lives in the scripts/ family (backlog_file defaults to
# `.scrum/backlog.json`). Reads backlog.json once and emits one TSV line
# "<id>\t<status>" per PBI in in_progress_* (excluding in_progress_merge);
# the id field may be empty. Callers derive count / ids / summary from this
# single snapshot so the filter and the backlog read are not duplicated per
# projection.
# Mirrors the `pbi_pipeline_active` in-flight filter in
# hooks/completion-gate.sh — a DIFFERENT process family. Per the documented
# no-cross-source convention between scripts/ and hooks/lib/ (see
# scripts/scrum/lib/atomic.sh / queries.sh), the two are kept in sync by hand,
# not shared; keep them in sync when changing the filter. Emits nothing on a
# missing / unparseable backlog.
in_flight_snapshot() {
  local backlog="${1:-.scrum/backlog.json}"
  if [ ! -f "$backlog" ] || ! jq empty "$backlog" >/dev/null 2>&1; then
    return 0
  fi
  jq -r '
    .items[]?
      | select(.status | startswith("in_progress_"))
      | select(.status != "in_progress_merge")
      | [(.id // ""), .status]
      | @tsv
  ' "$backlog" 2>/dev/null || true
}
