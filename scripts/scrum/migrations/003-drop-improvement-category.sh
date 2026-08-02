#!/usr/bin/env bash
# migrations/003-drop-improvement-category.sh — strip the deprecated
# `category` key from every .scrum/improvements.json entry. Idempotent: a
# second run is a no-op. Runs under scripts/scrum/migrate-state.sh (see its
# header for the migration contract: cwd = target root, idempotent,
# --dry-run, schema-validated writes, missing files are a clean no-op).
#
# Why this exists: e1958ec ("feat(scrum-state)!: drop deprecated improvements
# `category` field") removed the property from improvements.schema.json but
# shipped no migration, even though its own commit message says "Existing
# state files must be migrated (strip the key) before picking up this
# schema." Because entry items are `additionalProperties: false` and
# .scrum/improvements.json sits in migrate-state.sh's blocking STRICT_MAP,
# any project whose improvements.json predates 2026-07-02 hard-fails the
# launch gate (exit 65) and the team never spawns. This closes that gap and
# restores the framework's stated contract that a breaking schema change
# ships its migration in the same change.
#
# Usage: scripts/scrum/migrations/003-drop-improvement-category.sh [--dry-run]
# Runs in the cwd against .scrum/improvements.json. Prints a one-line summary.
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  "")           : ;;
  *)            echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/errors.sh
source "$HERE/../lib/errors.sh"
# shellcheck source=../lib/atomic.sh
source "$HERE/../lib/atomic.sh"

PATHF=".scrum/improvements.json"

if [ ! -f "$PATHF" ]; then
  echo "[003-drop-improvement-category] skip: $PATHF not present"
  exit 0
fi

# Count entries still carrying the key before mutation.
CARRYING_BEFORE="$(jq '
  [.entries[]? | select(has("category"))] | length
' "$PATHF")"

if [ "$CARRYING_BEFORE" -eq 0 ]; then
  printf '[003-drop-improvement-category] no-op: no entry carries category (%d entries)\n' \
    "$(jq '.entries | length' "$PATHF")"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '[003-drop-improvement-category] would strip category from %d entries (dry-run; no file written)\n' \
    "$CARRYING_BEFORE"
  exit 0
fi

# Delete only `category`. Every other key is left untouched — an unexpected
# extra key must still fail validation loudly rather than be silently
# swallowed by a blanket "drop unknown properties" pass.
EXPR='.entries |= map(del(.category))'

# Shared source/deployed-layout probe (lib/atomic.sh). Resolved only on the
# write path so the missing-file no-op above stays schema-independent.
SCHEMA="$(resolve_schema_dir)/improvements.schema.json"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

CARRYING_AFTER="$(jq '
  [.entries[]? | select(has("category"))] | length
' "$PATHF")"

printf '[003-drop-improvement-category] stripped category from %d entries (remaining: %d)\n' \
  "$CARRYING_BEFORE" "$CARRYING_AFTER"
