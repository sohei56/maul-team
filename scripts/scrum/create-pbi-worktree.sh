#!/usr/bin/env bash
# scripts/scrum/create-pbi-worktree.sh — create per-PBI git worktree + branch + symlink.
# Records branch/worktree/base_sha in pbi state.json. Idempotent.
#
# Usage: create-pbi-worktree.sh <pbi-id> [--base <sha>]
#
# The default base is `sprint.base_sha`, frozen once at Sprint start so every
# PBI of the Sprint forks from the same commit and parallel worktrees stay
# comparable. `--base` overrides it for work created AFTER the Sprint's PBIs
# have merged — the Sprint-end audit follow-up, which is filed against the
# merged HEAD. Forking such a PBI from the Sprint base would hand it a tree
# that predates the very drift the audit reported. `sprint.base_sha` is frozen
# exactly once and cannot be re-frozen, so the override lives here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

PBI=""
BASE_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) BASE_OVERRIDE="${2:-}"; shift 2 ;;
    -*)     fail E_INVALID_ARG "unknown flag: $1 (usage: create-pbi-worktree.sh <pbi-id> [--base <sha>])" ;;
    *)
      [ -z "$PBI" ] || fail E_INVALID_ARG "usage: create-pbi-worktree.sh <pbi-id> [--base <sha>]"
      PBI="$1"; shift 1 ;;
  esac
done
[ -n "$PBI" ] || fail E_INVALID_ARG "usage: create-pbi-worktree.sh <pbi-id> [--base <sha>]"
assert_pbi_id "$PBI"

SPRINT=".scrum/sprint.json"
STATE=".scrum/pbi/$PBI/state.json"
[ -f "$SPRINT" ] || fail E_FILE_MISSING "$SPRINT"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

if [ -n "$BASE_OVERRIDE" ]; then
  BASE="$(git rev-parse --verify "$BASE_OVERRIDE^{commit}" 2>/dev/null || true)"
  [ -n "$BASE" ] || fail E_INVALID_ARG "--base does not resolve to a commit: $BASE_OVERRIDE"
else
  BASE="$(jq -r '.base_sha // ""' "$SPRINT")"
  [ -n "$BASE" ] || fail E_INVALID_ARG "sprint.base_sha is empty — run freeze-sprint-base.sh first"
fi

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
