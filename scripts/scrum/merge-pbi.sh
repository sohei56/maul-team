#!/usr/bin/env bash
# scripts/scrum/merge-pbi.sh — SM-side merge orchestrator.
# Phases: pre-check → no-ff merge → artifact verify → quality-gate → record → cleanup.
# Failure modes call mark-pbi-merge-failure.sh and roll back main.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: merge-pbi.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PHASE="$(jq -r '.phase' "$STATE")"
[ "$PHASE" = "ready_to_merge" ] || fail E_INVALID_ARG "expected phase=ready_to_merge, got $PHASE"
BRANCH="$(jq -r '.branch' "$STATE")"

# Read paths_touched — portable (Bash 3.2+)
PATHS=()
while IFS= read -r line; do
  PATHS+=("$line")
done < <(jq -r '.paths_touched[]' "$STATE")

# Lock main worktree against parallel merges (mkdir-based, macOS compatible)
mkdir -p .scrum/.locks
MERGE_LOCK_DIR=".scrum/.locks/merge.lock.d"
LOCK_TIMEOUT_SEC="${SCRUM_LOCK_TIMEOUT:-30}"
LOCK_POLL_SEC="${SCRUM_LOCK_POLL:-0.05}"
_lock_iters="$(awk -v t="$LOCK_TIMEOUT_SEC" -v p="$LOCK_POLL_SEC" 'BEGIN{print int(t/p)+1}')"
_lock_i=0
while ! mkdir "$MERGE_LOCK_DIR" 2>/dev/null; do
  _lock_i=$((_lock_i + 1))
  if [ "$_lock_i" -ge "$_lock_iters" ]; then
    fail E_LOCK_TIMEOUT "another merge is in progress (lock: $MERGE_LOCK_DIR)"
  fi
  sleep "$LOCK_POLL_SEC"
done
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

# Run quality-gate (skippable for tests)
if [ "${SCRUM_SKIP_QUALITY_GATE:-0}" != "1" ]; then
  REPORT=".scrum/pbi/$PBI/quality-gate-out.log"
  mkdir -p ".scrum/pbi/$PBI"
  if ! "$ROOT/hooks/quality-gate.sh" >"$REPORT" 2>&1; then
    # Record the failure BEFORE rolling back (see artifact_missing path).
    "$HERE/mark-pbi-merge-failure.sh" "$PBI" regression "$PRE_HEAD" "$REPORT"
    git reset --hard "$PRE_HEAD" >/dev/null \
      || fail E_INVALID_ARG "CRITICAL: rollback failed after regression — main is at merged commit, manual intervention required (PRE_HEAD=$PRE_HEAD; report=$REPORT)"
    fail E_INVALID_ARG "merge_regression — see $REPORT"
  fi
fi

MERGED_SHA="$(git rev-parse HEAD)"
"$HERE/mark-pbi-merged.sh" "$PBI" "$MERGED_SHA"

# Cleanup the worktree + branch (phase is now merged — cleanup will succeed)
"$HERE/cleanup-pbi-worktree.sh" "$PBI"

printf '[merge-pbi] %s merged at %s\n' "$PBI" "$MERGED_SHA"
