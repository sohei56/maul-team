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

# Exit-code contract consumed by skills/pbi-merge/SKILL.md § Steps. This is
# DISTINCT from lib/errors.sh `fail` (which maps E_* names to 64..67): the SM
# branches its recovery on THESE codes, so every merge-pbi exit must resolve to
# one of them.
#   0  merged + cleanup complete.
#   1  preflight / infra failure — nothing was recorded and main is unchanged;
#      SM fixes the precondition and re-runs (NOT a 3-strike attempt, do NOT
#      read merge_failure.kind).
#   2  a merge failure was recorded THIS attempt (conflict|artifact_missing|
#      regression) and main is back at its pre-merge HEAD — the ONLY exit where
#      SM reads merge_failure.kind and runs the 3-strike recovery matrix.
#   3  the merge commit landed but post-merge bookkeeping/cleanup (or a rollback
#      after a recorded failure) did not complete — main was mutated; SM
#      verifies/repairs manually and NEVER routes to the failure matrix.
# `die` emits these; the EXIT trap (_merge_cleanup) normalizes any stray
# fail-based (64/67) or `set -e` exit into this space (see its comment).
die() {
  local rc="$1"; shift
  printf '[merge-pbi] %s\n' "$*" >&2
  exit "$rc"
}

# Tracks whether the merge commit has landed on main, so the EXIT trap can map
# an unexpected exit to 3 (main mutated) rather than 1 (nothing happened).
MERGE_PHASE=preflight

[ "$#" -eq 1 ] || die 1 "usage: merge-pbi.sh <pbi-id>"
PBI="$1"
# assert_pbi_id / assert_scrum_untracked call `fail` (exit 64) on violation;
# run them in a subshell so that becomes a preflight exit 1, not a raw 64.
( assert_pbi_id "$PBI" ) || die 1 "invalid pbi-id: $PBI"

# Pre-flight: .scrum/ must remain untracked. When tracked, branch switches
# silently delete state files that exist only on the current branch.
( assert_scrum_untracked ) || die 1 ".scrum/ is tracked in git — runtime state must stay untracked (see message above)"

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || die 1 "state file missing: $STATE"
BACKLOG=".scrum/backlog.json"
[ -f "$BACKLOG" ] || die 1 "backlog file missing: $BACKLOG"
STATUS="$(get_pbi_status "$PBI" "$BACKLOG")"
[ "$STATUS" = "in_progress_merge" ] \
  || die 1 "expected backlog status=in_progress_merge, got '$STATUS'"
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
# `_acquire_lock` calls `fail` (exit 66) on timeout. Run it in a subshell so a
# timeout resolves to preflight exit 1 — and, crucially, the trap that removes
# the lock is installed only AFTER acquisition succeeds, so a timeout (we do
# NOT hold the lock) never deletes another merge's lock directory.
( _acquire_lock "$MERGE_LOCK_DIR" ) || die 1 "could not acquire merge lock: $MERGE_LOCK_DIR"
# Cleanup on any exit: restore stashed out-of-scope drift (if any), drop the
# merge lock, and normalize the exit code to the 0/1/2/3 contract. Defined as a
# function so STASHED is read at fire time.
STASHED=0
_merge_cleanup() {
  local rc=$?
  if [ "${STASHED:-0}" = "1" ]; then
    git stash pop >/dev/null 2>&1 \
      || printf '[merge-pbi] WARN: could not auto-restore stashed working-tree drift; recover manually with: git stash pop\n' >&2
  fi
  rmdir "$MERGE_LOCK_DIR" 2>/dev/null || true
  # Normalize to the documented 0/1/2/3 exit contract. Explicit `die` calls
  # already emit 1/2/3 (passed through untouched); only a fail-based guard exit
  # (64/67) or an unexpected `set -e` trip reaches the default arm. Once the
  # merge commit has landed (MERGE_PHASE=merged) any such stray exit means main
  # was mutated → 3 (manual repair), never 1 (which claims nothing happened).
  case "$rc" in
    0|1|2|3) ;;
    *) if [ "${MERGE_PHASE:-preflight}" = "merged" ]; then rc=3; else rc=1; fi ;;
  esac
  exit "$rc"
}
trap _merge_cleanup EXIT

# Merge-scoped clean check. A blanket "main must be fully clean" check strands
# an unrelated PBI merge behind working-tree drift the merge would never touch
# (a leaked catalog spec, a framework-file edit on a disjoint path) — a failure
# mode that repeatedly halted whole autonomous Sprints. Refuse ONLY when the
# drift intersects the files THIS merge modifies (git would refuse those
# anyway). Disjoint tracked drift is stashed across the merge so a post-merge
# rollback (`git reset --hard`) cannot destroy it, then restored by the trap.
COLLIDE="$(merge_colliding_dirt "$BRANCH")"
if [ "$COLLIDE" = "__NO_BASE__" ]; then
  die 1 "no merge base between current branch and '$BRANCH'; refusing to merge a dirty tree"
fi
if [ -n "$COLLIDE" ]; then
  CSV="$(printf '%s' "$COLLIDE" | tr '\n' ',' | sed 's/,$//')"
  die 1 "refuse to merge: working tree has uncommitted changes to files this merge modifies: $CSV"
fi
if [ -n "$(git diff --name-only HEAD 2>/dev/null || true)" ]; then
  # Dirty but disjoint from the merge set — protect it across the merge.
  if git stash push -m "merge-pbi:$PBI disjoint-drift" >/dev/null 2>&1; then
    STASHED=1
    printf '[merge-pbi] WARN: stashed out-of-scope working-tree drift across the merge (auto-restored after)\n' >&2
  else
    die 1 "failed to stash out-of-scope working-tree drift; refusing to merge"
  fi
fi

PRE_HEAD="$(git rev-parse HEAD)"

# Refuse to auto-switch to main — switching branches mid-merge silently
# destroys branch-local files when .scrum/ has ever been tracked.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "main" ] \
  || die 1 "merge-pbi.sh must run with 'main' checked out (current: '$CURRENT_BRANCH')"

# Attempt merge
if ! git merge --no-ff "$BRANCH" -m "merge: $PBI" >/dev/null 2>&1; then
  # Conflict — collect conflicting paths, abort, record. The abort restores
  # main exactly, so nothing landed: a successful record → exit 2 (failure
  # matrix); a FAILED record → exit 1 (nothing recorded, main clean, safe to
  # re-run) rather than a misleading exit 2 the SM would route on stale kind.
  CONFLICT_PATHS="$(git diff --name-only --diff-filter=U | tr '\n' ',' | sed 's/,$//')"
  git merge --abort 2>/dev/null || true
  if "$HERE/mark-pbi-merge-failure.sh" "$PBI" conflict "$PRE_HEAD" "${CONFLICT_PATHS:-unknown}"; then
    die 2 "merge conflict: ${CONFLICT_PATHS:-unknown}"
  fi
  die 1 "merge conflict, but failed to record merge_failure for $PBI (nothing recorded; main left clean after abort)"
fi

# The merge commit is now on main. From here a stray exit means main was
# mutated: the trap maps any un-die'd exit to 3, not 1.
MERGE_PHASE=merged

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
  if ! "$HERE/mark-pbi-merge-failure.sh" "$PBI" artifact_missing "$PRE_HEAD" "$CSV"; then
    # Bookkeeping failed with a merge commit on main and nothing recorded.
    # Roll back best-effort, then exit 3: the SM must NOT run the failure
    # matrix (there is no merge_failure.kind to read) and must verify main.
    git reset --hard "$PRE_HEAD" >/dev/null 2>&1 || true
    die 3 "CRITICAL: artifact_missing but failed to record merge_failure for $PBI — verify main is at $PRE_HEAD (rollback attempted); do NOT route to the failure matrix"
  fi
  if git reset --hard "$PRE_HEAD" >/dev/null; then
    die 2 "artifact_missing: $CSV"
  fi
  die 3 "CRITICAL: rollback failed after artifact_missing — main is at merged commit, manual intervention required (PRE_HEAD=$PRE_HEAD)"
fi

# Regression gate: run a project-configured command from the main repo
# root after the merge commit lands. Absent/empty/null → skip with WARN.
REG_LOG=".scrum/pbi/$PBI/merge-regression.log"
REG_CMD=""
REG_ACCEPTED_NONE="false"
if [ -f .scrum/config.json ]; then
  REG_CMD="$(jq -r '.merge_regression.command // ""' .scrum/config.json)"
  REG_ACCEPTED_NONE="$(jq -r '.merge_regression.accepted_none // false' .scrum/config.json)"
fi
if [ -z "$REG_CMD" ] || [ "$REG_CMD" = "null" ]; then
  if [ "$REG_ACCEPTED_NONE" = "true" ]; then
    # Explicit, logged opt-out (set-merge-regression-command.sh --none, a
    # Sprint-Planning decision). The team chose no gate — do NOT spam a WARN
    # or PO attention every merge; a single quiet note suffices.
    printf '[merge-pbi] note: no per-PBI regression gate this project (accepted via set-merge-regression-command.sh --none)\n'
  else
    printf '[merge-pbi] WARN: merge_regression.command unset — regression gate SKIPPED for this merge. Configure via .scrum/scripts/set-merge-regression-command.sh '\''<cmd>'\'' (or record --none)\n'
    # In autonomous mode a console WARN is read by nobody, so an
    # undecided gate means every per-PBI merge lands ungated in
    # silence (a target project shipped a broken test suite to main this
    # way, Sprint after Sprint). Surface it to PO attention once per
    # Sprint (deduped by a sprint-id marker line).
    PO_MODE="$(jq -r '.po_mode // "human"' .scrum/config.json 2>/dev/null || echo human)"
    if [ "$PO_MODE" = "agent" ] && [ -f .scrum/sprint.json ]; then
      ATTN_SPRINT="$(jq -r '.id // ""' .scrum/sprint.json)"
      ATTN_FILE=".scrum/po/attention.md"
      ATTN_MARK="merge_regression.command unconfigured ($ATTN_SPRINT)"
      if [ -n "$ATTN_SPRINT" ] && ! grep -qF "$ATTN_MARK" "$ATTN_FILE" 2>/dev/null; then
        mkdir -p .scrum/po
        printf -- '- [%s] %s: per-PBI merges land with the regression gate skipped; run .scrum/scripts/set-merge-regression-command.sh (configure a command or --none)\n' \
          "$(_iso_utc_now)" "$ATTN_MARK" >> "$ATTN_FILE"
      fi
    fi
  fi
else
  if ! bash -c "$REG_CMD" >"$REG_LOG" 2>&1; then
    # Record the failure BEFORE rolling back so state stays consistent
    # even if the reset fails (mirrors artifact_missing ordering).
    if ! "$HERE/mark-pbi-merge-failure.sh" "$PBI" regression "$PRE_HEAD" "$REG_LOG"; then
      git reset --hard "$PRE_HEAD" >/dev/null 2>&1 || true
      die 3 "CRITICAL: regression but failed to record merge_failure for $PBI — verify main is at $PRE_HEAD (rollback attempted); do NOT route to the failure matrix"
    fi
    if git reset --hard "$PRE_HEAD" >/dev/null; then
      die 2 "regression: tests failed after merge — see $REG_LOG"
    fi
    die 3 "CRITICAL: rollback failed after regression — main is at merged commit, manual intervention required (PRE_HEAD=$PRE_HEAD)"
  fi
fi

# Post-merge bookkeeping. The merge is on main; a failure here is exit 3 (never
# the failure matrix) — the PBI is effectively merged, only bookkeeping/cleanup
# is incomplete and must be repaired by re-running the named wrapper.
MERGED_SHA="$(git rev-parse HEAD)"
"$HERE/mark-pbi-merged.sh" "$PBI" "$MERGED_SHA" \
  || die 3 "merge landed at $MERGED_SHA but mark-pbi-merged.sh failed — backlog/state not flipped to awaiting_cross_review; re-run: mark-pbi-merged.sh $PBI $MERGED_SHA"

# Cleanup the worktree + branch (status is now awaiting_cross_review — cleanup will succeed)
"$HERE/cleanup-pbi-worktree.sh" "$PBI" \
  || die 3 "merge recorded (merged_sha=$MERGED_SHA) but cleanup-pbi-worktree.sh failed — remove .scrum/worktrees/$PBI + branch pbi/$PBI manually"

printf '[merge-pbi] %s merged at %s\n' "$PBI" "$MERGED_SHA"
