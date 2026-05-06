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

SHA="$(git rev-parse HEAD)"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

atomic_write "$SPRINT" \
  ".base_sha = \"$SHA\" | .base_sha_captured_at = \"$NOW\"" \
  "$SCHEMA"
printf '[freeze-sprint-base] frozen at %s (%s)\n' "$SHA" "$NOW"
