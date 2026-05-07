#!/usr/bin/env bash
# scripts/scrum/merge-pbi.sh — SM-side merge orchestrator.
# Phases: pre-check → no-ff merge → artifact verify → record → cleanup.
# Failure modes call mark-pbi-merge-failure.sh and roll back main.
# Quality verification (lint/test) is performed Sprint-end by cross-review,
# not per-PBI merge.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Merge takes longer than atomic_write (git ops + artifact verify); raise the
# default lock timeout. External override via SCRUM_LOCK_TIMEOUT still wins.
: "${SCRUM_LOCK_TIMEOUT:=30}"
export SCRUM_LOCK_TIMEOUT
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: merge-pbi.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
BACKLOG=".scrum/backlog.json"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG"
STATUS="$(jq -r --arg id "$PBI" '.items[] | select(.id==$id).status // ""' "$BACKLOG")"
[ "$STATUS" = "in_progress_merge" ] \
  || fail E_INVALID_ARG "expected backlog status=in_progress_merge, got '$STATUS'"
BRANCH="$(jq -r '.branch' "$STATE")"

# Read paths_touched — portable (Bash 3.2+)
PATHS=()
while IFS= read -r line; do
  PATHS+=("$line")
done < <(jq -r '.paths_touched[]' "$STATE")

# Lock main worktree against parallel merges (mkdir-based, macOS compatible).
# `_acquire_lock` is the canonical helper from lib/atomic.sh.
mkdir -p "$SCRUM_LOCK_DIR"
MERGE_LOCK_DIR="$SCRUM_LOCK_DIR/merge.lock.d"
_acquire_lock "$MERGE_LOCK_DIR"
# shellcheck disable=SC2064
trap "rmdir '$MERGE_LOCK_DIR' 2>/dev/null || true" EXIT

# Working tree must have no staged/modified/deleted tracked-file changes
# (untracked files are ignored — .scrum/ is not versioned)
if git status --porcelain | grep -qv '^??'; then
  fail E_INVALID_ARG "main worktree has uncommitted changes — refuse to merge"
fi

PRE_HEAD="$(git rev-parse HEAD)"

# Ensure we are on main
git checkout main >/dev/null 2>&1 || fail E_INVALID_ARG "could not checkout main"

# Attempt merge
if ! git merge --no-ff "$BRANCH" -m "merge: $PBI" >/dev/null 2>&1; then
  # Conflict — collect conflicting paths, abort, record
  CONFLICT_PATHS="$(git diff --name-only --diff-filter=U | tr '\n' ',' | sed 's/,$//')"
  git merge --abort 2>/dev/null || true
  "$HERE/mark-pbi-merge-failure.sh" "$PBI" conflict "$PRE_HEAD" "${CONFLICT_PATHS:-unknown}"
  fail E_INVALID_ARG "merge conflict: ${CONFLICT_PATHS:-unknown}"
fi

# Verify artifacts present at HEAD
MISSING=()
for p in "${PATHS[@]}"; do
  if ! git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    MISSING+=("$p")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  CSV="${MISSING[*]}"
  CSV="${CSV// /,}"
  # Record the failure BEFORE rolling back so state stays consistent even if
  # the reset fails (e.g., disk error, locked working tree).
  "$HERE/mark-pbi-merge-failure.sh" "$PBI" artifact_missing "$PRE_HEAD" "$CSV"
  git reset --hard "$PRE_HEAD" >/dev/null \
    || fail E_INVALID_ARG "CRITICAL: rollback failed after artifact_missing — main is at merged commit, manual intervention required (PRE_HEAD=$PRE_HEAD)"
  fail E_INVALID_ARG "artifact_missing: $CSV"
fi

MERGED_SHA="$(git rev-parse HEAD)"
"$HERE/mark-pbi-merged.sh" "$PBI" "$MERGED_SHA"

# Cleanup the worktree + branch (status is now awaiting_cross_review — cleanup will succeed)
"$HERE/cleanup-pbi-worktree.sh" "$PBI"

printf '[merge-pbi] %s merged at %s\n' "$PBI" "$MERGED_SHA"
