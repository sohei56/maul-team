#!/usr/bin/env bash
# scripts/scrum/safe-switch-to-main.sh — guarded `git checkout main` for the
# main worktree. Intended for SM recovery when a previous session left the
# main worktree on a feature branch and merge-pbi.sh refuses to run.
#
# Pre-flight invariants (matched against merge-pbi.sh):
#   - .scrum/ must NOT be tracked in git (switching with tracked .scrum/
#     silently deletes branch-local state files).
#   - Working tree must have no tracked-file changes (untracked OK; .scrum/
#     is untracked by design).
#
# Asymmetry with merge-pbi.sh, on purpose: merge-pbi.sh uses the merge-SCOPED
# check (`merge_colliding_dirt`, lib/git-guards.sh) because a blanket check
# stranded whole Sprints behind drift the merge never touched. A branch switch
# has no "merge set" to scope against — git may clobber ANY dirty tracked path
# — so this script keeps the BLANKET check. Consequence: unrelated tracked
# working-tree drift blocks it even though it would not block merge-pbi.sh.
# The operator's recovery is to commit or revert that drift (in a PBI worktree,
# via commit-pbi.sh) before re-running; this script deliberately does not stash
# on the operator's behalf.
#
# No-op when already on main. Never touches branches besides switching to
# `main` — does not create, delete, or fast-forward.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/git-guards.sh
source "$HERE/lib/git-guards.sh"

[ "$#" -eq 0 ] || fail E_INVALID_ARG "usage: safe-switch-to-main.sh"

assert_scrum_untracked
assert_clean_worktree "refuse to switch"

# Confirm `main` exists.
if ! git show-ref --verify --quiet refs/heads/main; then
  fail E_INVALID_ARG "branch 'main' does not exist in this repository"
fi

CUR="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CUR" = "main" ]; then
  printf '[safe-switch-to-main] already on main\n'
  exit 0
fi

git checkout main >/dev/null 2>&1
printf '[safe-switch-to-main] now on main (was on %s)\n' "$CUR"
