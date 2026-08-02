#!/usr/bin/env bash
# migrations/004-drop-pbi-state-phase.sh — strip the legacy `phase` key from
# every .scrum/pbi/<pbi-id>/state.json. Idempotent: a second run is a no-op.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated
# writes, missing files are a clean no-op).
#
# Why this exists: 001-legacy-to-ssot.sh deliberately does NOT rewrite
# per-PBI files, on the stated grounds that "their schema is strict and
# projects in flight legitimately carry richer fields". Those two clauses
# contradict each other — pbi-state.schema.json is `additionalProperties:
# false`, so a "richer field" is exactly what it rejects. The v1 `phase`
# field was removed when readers moved to backlog.json.items[].status (the
# 13-value SSOT), and migrate-state.sh validates every
# .scrum/pbi/*/state.json in its BLOCKING batch pass. Net effect before this
# migration: a v1 per-PBI file still carrying `phase` hard-fails the launch
# gate with no repair path. This supplies the repair.
#
# Scope is deliberately narrow: only `phase` is deleted. Any OTHER unknown
# key must still fail validation loudly — a blanket "drop unknown
# properties" pass would silently swallow real corruption.
#
# Usage: scripts/scrum/migrations/004-drop-pbi-state-phase.sh [--dry-run]
# Runs in the cwd against .scrum/pbi/*/state.json. Prints a one-line summary.
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

PBI_DIR=".scrum/pbi"

if [ ! -d "$PBI_DIR" ]; then
  echo "[004-drop-pbi-state-phase] skip: $PBI_DIR not present"
  exit 0
fi

# Collect the files that actually carry the key, so both the dry-run report
# and the no-op path stay schema-independent (no schema resolution needed
# unless there is something to write).
CARRYING=""
TOTAL=0
for f in "$PBI_DIR"/*/state.json; do
  [ -e "$f" ] || continue
  TOTAL=$((TOTAL + 1))
  # A malformed/unreadable file is left for the launch gate to report by
  # name — this migration must not mask it.
  if jq -e 'has("phase")' "$f" >/dev/null 2>&1; then
    CARRYING="$CARRYING$f
"
  fi
done

CARRYING_COUNT=0
[ -n "$CARRYING" ] && CARRYING_COUNT="$(printf '%s' "$CARRYING" | grep -c '^')"

if [ "$CARRYING_COUNT" -eq 0 ]; then
  printf '[004-drop-pbi-state-phase] no-op: no per-PBI state carries phase (%d files)\n' "$TOTAL"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '[004-drop-pbi-state-phase] would strip phase from %d of %d per-PBI state files (dry-run; no file written)\n' \
    "$CARRYING_COUNT" "$TOTAL"
  exit 0
fi

# Shared source/deployed-layout probe (lib/atomic.sh).
SCHEMA="$(resolve_schema_dir)/pbi-state.schema.json"

MIGRATED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  atomic_write "$f" 'del(.phase)' "$SCHEMA"
  MIGRATED=$((MIGRATED + 1))
done <<EOF
$CARRYING
EOF

printf '[004-drop-pbi-state-phase] stripped phase from %d of %d per-PBI state files\n' \
  "$MIGRATED" "$TOTAL"
