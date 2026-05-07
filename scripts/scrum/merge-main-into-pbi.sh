#!/usr/bin/env bash
# scripts/scrum/merge-main-into-pbi.sh — bring main forward into a PBI branch.
# SM runs this from the main worktree when merge-pbi.sh fails with `conflict`
# (Developer cannot run raw `git rebase` — pre-tool-use-no-branch-ops blocks it).
#
# Behaviour:
#   - Captures `git rev-parse main` from the main worktree.
#   - Runs `git -C .scrum/worktrees/<pbi-id> merge --no-ff <main-sha>` inside
#     the PBI worktree (which is checked out at branch `pbi/<pbi-id>`).
#   - Clean merge → records the new HEAD, prints success.
#   - Conflict → leaves the worktree in mid-merge state and exits non-zero.
#     The Developer resolves conflicts in-place, then commits via
#     `commit-pbi.sh` and re-notifies via `mark-pbi-ready-to-merge.sh`.
#   - Already up-to-date (main is ancestor of PBI HEAD) → no-op success.
#
# This wrapper does NOT touch backlog status or merge_failure state. The
# subsequent `merge-pbi.sh` retry is what advances the PBI to
# `awaiting_cross_review`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: merge-main-into-pbi.sh <pbi-id>"
PBI="$1"
case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac

# .scrum/ must remain untracked in the main worktree — same invariant
# enforced by merge-pbi.sh. Branch switches with tracked .scrum/ silently
# delete state files.
if [ -n "$(git ls-files .scrum/ 2>/dev/null)" ]; then
  fail E_INVALID_ARG ".scrum/ is tracked in git — runtime state must stay untracked. Recover with: git rm -r --cached .scrum/ && echo '.scrum/' >> .gitignore"
fi

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
WT="$(jq -r '.worktree // ""' "$STATE")"
EXPECTED_BRANCH="$(jq -r '.branch // ""' "$STATE")"
[ -n "$WT" ] && [ -d "$WT" ] || fail E_FILE_MISSING "PBI worktree missing: $WT"
[ -n "$EXPECTED_BRANCH" ] || fail E_INVALID_ARG "state.branch unset for $PBI"

CUR_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
if [ "$CUR_BRANCH" != "$EXPECTED_BRANCH" ]; then
  fail E_INVALID_ARG "worktree on wrong branch: have=$CUR_BRANCH expected=$EXPECTED_BRANCH"
fi

# Refuse if PBI worktree has tracked changes. The Developer must commit (or
# stash) in-progress work via commit-pbi.sh before SM brings main forward.
if git -C "$WT" status --porcelain | grep -qv '^??'; then
  fail E_INVALID_ARG "PBI worktree $WT has uncommitted tracked changes — Developer must commit via commit-pbi.sh first"
fi

# Resolve main HEAD from the main worktree.
MAIN_SHA="$(git rev-parse main)"

# Already-ancestor short-circuit: nothing to do.
if git -C "$WT" merge-base --is-ancestor "$MAIN_SHA" HEAD; then
  printf '[merge-main-into-pbi] %s already contains main (%s) — no-op\n' "$EXPECTED_BRANCH" "$MAIN_SHA"
  exit 0
fi

# Attempt merge. --no-ff keeps the merge commit explicit; the Developer's
# subsequent `mark-pbi-ready-to-merge.sh` re-stamps head_sha + paths_touched.
if git -C "$WT" merge --no-ff "$MAIN_SHA" -m "merge: main into $EXPECTED_BRANCH" >/dev/null 2>&1; then
  NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
  printf '[merge-main-into-pbi] %s ← main(%s) merged cleanly @ %s\n' "$EXPECTED_BRANCH" "$MAIN_SHA" "$NEW_HEAD"
  exit 0
fi

# Conflict — capture paths, leave worktree in merge state for Developer.
CONFLICT_PATHS="$(git -C "$WT" diff --name-only --diff-filter=U | tr '\n' ',' | sed 's/,$//')"
printf '[merge-main-into-pbi] CONFLICT %s ← main(%s) in: %s\n' "$EXPECTED_BRANCH" "$MAIN_SHA" "${CONFLICT_PATHS:-unknown}" >&2
printf '[merge-main-into-pbi] Developer resolves conflicts in %s, runs commit-pbi.sh, then mark-pbi-ready-to-merge.sh\n' "$WT" >&2
exit 1
