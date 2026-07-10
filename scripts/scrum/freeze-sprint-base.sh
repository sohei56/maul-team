#!/usr/bin/env bash
# scripts/scrum/freeze-sprint-base.sh — capture sprint.base_sha once at Sprint start.
# Idempotency: refuses to overwrite a non-null base_sha (call exactly once per Sprint).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

SPRINT=".scrum/sprint.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/sprint.schema.json"
[ -f "$SPRINT" ] || fail E_FILE_MISSING "$SPRINT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail E_INVALID_ARG "freeze-sprint-base: not inside a git repo"

if jq -e 'has("base_sha") and .base_sha != null and .base_sha != ""' "$SPRINT" >/dev/null 2>&1; then
  fail E_INVALID_ARG "sprint.base_sha already frozen — call exactly once per Sprint"
fi

# Scaffold→commit→freeze ordering guard. base_sha captures committed HEAD
# only; PBI worktrees fork from it. A scaffolded design-spec stub (or a
# catalog-config enable) left uncommitted here is invisible to every
# worktree — a target project shipped a PBI with NO design spec because
# the stub never made it into the base. Refuse until docs/design/ is
# committed (sprint-planning Step 13 owns the commit).
# -uall expands untracked directories to individual files so the error
# names the actual stubs, not a bare "docs/design/" line.
DIRTY_DESIGN="$(git status --porcelain -uall -- docs/design/ 2>/dev/null || true)"
if [ -n "$DIRTY_DESIGN" ]; then
  DIRTY_CSV="$(printf '%s\n' "$DIRTY_DESIGN" | awk '{print $NF}' | tr '\n' ',' | sed 's/,$//')"
  fail E_INVALID_ARG "freeze-sprint-base: uncommitted docs/design/ changes would be excluded from base_sha (worktrees fork from committed HEAD): $DIRTY_CSV — commit scaffold stubs + catalog-config first"
fi

SHA="$(git rev-parse HEAD)"
NOW="$(_iso_utc_now)"

atomic_write "$SPRINT" \
  ".base_sha = \"$SHA\" | .base_sha_captured_at = \"$NOW\"" \
  "$SCHEMA"
printf '[freeze-sprint-base] frozen at %s (%s)\n' "$SHA" "$NOW"
