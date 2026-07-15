#!/usr/bin/env bash
# scripts/scrum/cleanup-pbi-worktree.sh — remove worktree + branch after cross-review done or escalation.
# Idempotent. Refuses for non-terminal status to prevent accidental work loss.
# Terminal status (cleanup allowed): awaiting_cross_review, cross_review, escalated, done, cancelled.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: cleanup-pbi-worktree.sh <pbi-id>"
PBI="$1"
assert_pbi_id "$PBI"

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
BACKLOG=".scrum/backlog.json"
[ -f "$BACKLOG" ] || fail E_FILE_MISSING "$BACKLOG"
STATUS="$(get_pbi_status "$PBI" "$BACKLOG")"
case "$STATUS" in
  awaiting_cross_review|cross_review|escalated|done|cancelled) ;;
  *) fail E_INVALID_ARG "refuse to cleanup pbi $PBI in status=$STATUS (need awaiting_cross_review|cross_review|escalated|done|cancelled)" ;;
esac

WT=".scrum/worktrees/$PBI"
BRANCH="pbi/$PBI"

if [ -d "$WT" ]; then
  git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
fi
if git show-ref --quiet --heads "$BRANCH"; then
  git branch -D "$BRANCH" >/dev/null
fi
# Prune git worktree metadata
git worktree prune >/dev/null 2>&1 || true

printf '[cleanup-pbi-worktree] removed %s and branch %s\n' "$WT" "$BRANCH"
