#!/usr/bin/env bash
# scripts/scrum/commit-integration-tests.sh — Testing-side commit wrapper for
# the target project's main worktree. The `integration-tests` skill writes test
# assets (tests/integration/, tests/e2e/, tests/stubs/) and commits them through
# this wrapper — the sole sanctioned path. Refuses unless phase is
# `integration_sprint` and the current branch is not a PBI worktree branch, and
# refuses to commit anything staged outside the test-asset allowlist.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -ge 1 ] || fail E_INVALID_ARG \
  "usage: commit-integration-tests.sh <message> [--allow <path>]..."
MSG="$1"; shift
ALLOW=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow)
      [ "$#" -ge 2 ] || fail E_INVALID_ARG "--allow requires a path"
      ALLOW+=("$2"); shift 2 ;;
    *) fail E_INVALID_ARG "unexpected argument: $1" ;;
  esac
done

# Guard 1: phase must be integration_sprint. The skill runs only in that phase;
# committing test assets in any other phase is a misuse.
STATE=".scrum/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PHASE="$(jq -r '.phase // ""' "$STATE")"
[ "$PHASE" = "integration_sprint" ] || fail E_INVALID_ARG \
  "phase must be integration_sprint (have: ${PHASE:-<unset>})"

# Guard 2: never run from a PBI worktree branch. This wrapper commits to the
# current branch (it never creates or switches branches); a pbi/* checkout
# means it was invoked from the wrong worktree.
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$CUR_BRANCH" in
  pbi/*) fail E_INVALID_ARG \
    "refusing to commit from PBI worktree branch: $CUR_BRANCH" ;;
esac

# Stage only the test-asset directories and any explicit --allow exception
# paths that actually exist. `git add <pathspec>` errors on a non-matching
# pathspec under `set -e`, so skip paths that are absent.
TEST_DIRS=(tests/integration tests/e2e tests/stubs)
for p in "${TEST_DIRS[@]}" ${ALLOW[@]+"${ALLOW[@]}"}; do
  [ -e "$p" ] && git add -- "$p"
done

# Exclude the .scrum symlink / tree for the same reason as commit-pbi.sh: the
# gitignore `.scrum/` pattern matches directories, not the git-type-120000
# symlink a worktree installs. Two-step (add then unstage) is robust whether
# `.scrum` is tracked, ignored, or absent.
git reset --quiet HEAD -- .scrum 2>/dev/null || true

if git diff --cached --quiet; then
  printf '[commit-integration-tests] nothing to commit\n'
  exit 0
fi

# Product-source mixing guard: every staged path must fall under a test-asset
# directory or an --allow exception. A pre-staged product-source file (staged
# by the caller before this wrapper ran) is caught here and blocks the commit.
path_allowed() {
  local f="$1" a
  case "$f" in
    tests/integration/*|tests/e2e/*|tests/stubs/*) return 0 ;;
  esac
  for a in ${ALLOW[@]+"${ALLOW[@]}"}; do
    [ "$f" = "$a" ] && return 0
    case "$f" in "$a"/*) return 0 ;; esac
  done
  return 1
}

BAD=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  path_allowed "$f" || BAD="$BAD $f"
done < <(git diff --cached --name-only)
[ -z "$BAD" ] || fail E_INVALID_ARG \
  "staged paths outside the test-asset allowlist:$BAD"

SUBJECT="test(integration): $MSG"
if [ "${#ALLOW[@]}" -gt 0 ]; then
  BODY="Staged via --allow (exception paths):"
  for a in "${ALLOW[@]}"; do
    BODY="$BODY"$'\n'"  $a"
  done
  git commit -q -m "$SUBJECT" -m "$BODY" >/dev/null
else
  git commit -q -m "$SUBJECT" >/dev/null
fi

NEW_HEAD="$(git rev-parse HEAD)"
printf '[commit-integration-tests] committed @ %s\n' "$NEW_HEAD"
