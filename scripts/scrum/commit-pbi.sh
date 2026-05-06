#!/usr/bin/env bash
# scripts/scrum/commit-pbi.sh — Developer-side commit wrapper for the PBI worktree.
# Verifies branch == pbi/<id> before committing. Updates state.head_sha after.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: commit-pbi.sh <pbi-id> <message>"
PBI="$1"; MSG="$2"
case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac

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

# Exclude the .scrum symlink that create-pbi-worktree.sh installs back to the
# main repo SSOT. Without this, `add -A` would stage it (gitignore's `.scrum/`
# pattern matches directories only, not symlinks of git type 120000) and the
# symlink would propagate to main on merge.
git -C "$WT" add -A -- ':!.scrum'
if git -C "$WT" diff --cached --quiet; then
  printf '[commit-pbi] nothing to commit\n'
  exit 0
fi
git -C "$WT" commit -m "$MSG" >/dev/null

NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
"$HERE/update-pbi-state.sh" "$PBI" head_sha "$NEW_HEAD"
printf '[commit-pbi] %s @ %s\n' "$PBI" "$NEW_HEAD"
