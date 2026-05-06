#!/usr/bin/env bash
# scripts/scrum/create-pbi-worktree.sh — create per-PBI git worktree + branch + symlink.
# Records branch/worktree/base_sha in pbi state.json. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: create-pbi-worktree.sh <pbi-id>"
PBI="$1"
case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac

SPRINT=".scrum/sprint.json"
STATE=".scrum/pbi/$PBI/state.json"
[ -f "$SPRINT" ] || fail E_FILE_MISSING "$SPRINT"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

BASE="$(jq -r '.base_sha // ""' "$SPRINT")"
[ -n "$BASE" ] || fail E_INVALID_ARG "sprint.base_sha is empty — run freeze-sprint-base.sh first"

WT=".scrum/worktrees/$PBI"
BRANCH="pbi/$PBI"

# Idempotent: if worktree exists and branch checked out matches, just sync state.
if [ -d "$WT" ]; then
  cur="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" = "$BRANCH" ]; then
    printf '[create-pbi-worktree] %s already exists, syncing state\n' "$WT"
  else
    fail E_INVALID_ARG "$WT exists but checked out branch is '$cur' (expected $BRANCH)"
  fi
else
  git worktree add -b "$BRANCH" "$WT" "$BASE" >/dev/null
fi

# Symlink .scrum/ in the worktree (relative, three levels up)
if [ ! -L "$WT/.scrum" ]; then
  (cd "$WT" && ln -s ../../../.scrum .scrum)
fi

# Sync pbi state. Use update-pbi-state.sh for schema-validated writes.
"$HERE/update-pbi-state.sh" "$PBI" \
  branch "$BRANCH" \
  worktree "$WT" \
  base_sha "$BASE"

printf '[create-pbi-worktree] ready: %s @ %s (branch %s)\n' "$WT" "$BASE" "$BRANCH"
