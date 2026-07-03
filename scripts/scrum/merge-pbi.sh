#!/usr/bin/env bash
# scripts/scrum/merge-pbi.sh — SM-side merge orchestrator.
# Phases: pre-check → no-ff merge → artifact verify → regression gate →
# record → cleanup. Failure modes call mark-pbi-merge-failure.sh and roll
# back main. The regression gate runs the command at
# `.scrum/config.json.merge_regression.command` (absent → gate skipped
# with WARN); the full Sprint-end lint/quality review still lives in
# cross-review.
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
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"
# shellcheck source=lib/git-guards.sh
source "$HERE/lib/git-guards.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: merge-pbi.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

# Pre-flight: .scrum/ must remain untracked. When tracked, branch switches
# silently delete state files that exist only on the current branch.
assert_scrum_untracked

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
BACKLOG=".scrum/backlog.json"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG"
STATUS="$(get_pbi_status "$PBI" "$BACKLOG")"
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
assert_clean_worktree "refuse to merge"

PRE_HEAD="$(git rev-parse HEAD)"

# Refuse to auto-switch to main — switching branches mid-merge silently
# destroys branch-local files when .scrum/ has ever been tracked.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "main" ] \
  || fail E_INVALID_ARG "merge-pbi.sh must run with 'main' checked out (current: '$CURRENT_BRANCH')"

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

# Regression gate: run a project-configured command from the main repo
# root after the merge commit lands. Absent/empty/null → skip with WARN.
REG_LOG=".scrum/pbi/$PBI/merge-regression.log"
REG_CMD=""
if [ -f .scrum/config.json ]; then
  REG_CMD="$(jq -r '.merge_regression.command // ""' .scrum/config.json)"
fi
if [ -z "$REG_CMD" ] || [ "$REG_CMD" = "null" ]; then
  printf '[merge-pbi] WARN: no merge regression command configured — skipping regression gate\n'
else
  if ! bash -c "$REG_CMD" >"$REG_LOG" 2>&1; then
    # Record the failure BEFORE rolling back so state stays consistent
    # even if the reset fails (mirrors artifact_missing ordering).
    "$HERE/mark-pbi-merge-failure.sh" "$PBI" regression "$PRE_HEAD" "$REG_LOG"
    git reset --hard "$PRE_HEAD" >/dev/null \
      || fail E_INVALID_ARG "CRITICAL: rollback failed after regression — main is at merged commit, manual intervention required (PRE_HEAD=$PRE_HEAD)"
    fail E_INVALID_ARG "regression: tests failed after merge — see $REG_LOG"
  fi
fi

MERGED_SHA="$(git rev-parse HEAD)"
"$HERE/mark-pbi-merged.sh" "$PBI" "$MERGED_SHA"

# NOTE: Worktree + branch cleanup is intentionally deferred to the cross-review
# skill (Step 13, when the PBI reaches status=done). The previous code called
# cleanup-pbi-worktree.sh here immediately after merge, which destroyed the
# worktree before cross-review could run. When cross-review aspect 1/2/3 FAIL
# reverts the PBI to in_progress_impl, the Developer must fix code in that
# same worktree and re-merge — an impossible operation if the worktree no
# longer exists. The cleanup-pbi-worktree.sh wrapper already accepts
# awaiting_cross_review as a valid status for removal, so the cross-review
# skill can call it at the right time.

printf '[merge-pbi] %s merged at %s\n' "$PBI" "$MERGED_SHA"
