#!/usr/bin/env bash
# scripts/scrum/migrate-add-kind-field.sh — backfill `kind: "code"` on every
# .scrum/backlog.json item that lacks it. One-shot migration for the
# doc-only-pbi-flow change (PR-1 .. PR-5). Idempotent: a second run is a no-op.
#
# Why default to "code": the boundary enforce in mark-pbi-ready-to-merge.sh
# treats absent/null kind as "code" already (the wrapper reads
# `(.kind // "code")`). This migration just makes that implicit default
# explicit in the file so dashboards / cross-review filters / refinement audit
# do not need a special "kind absent" branch — they can read `kind` and trust
# it. Items that were already explicitly tagged (`kind: "code"` or
# `kind: "docs"`) are left untouched.
#
# Usage: migrate-add-kind-field.sh
# Runs in the cwd against .scrum/backlog.json. Prints a one-line summary.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF"

# Count items missing kind before mutation.
MISSING_BEFORE="$(jq '
  [.items[] | select(has("kind") | not)] | length
' "$PATHF")"

if [ "$MISSING_BEFORE" -eq 0 ]; then
  printf '[migrate-add-kind-field] no-op: all %d items already have kind\n' \
    "$(jq '.items | length' "$PATHF")"
  exit 0
fi

# Add kind: "code" only to items that don't already have it; leave the rest
# alone (including any items where the user has set kind: "docs" already).
EXPR='.items |= map(if has("kind") then . else .kind = "code" end)'

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

MISSING_AFTER="$(jq '
  [.items[] | select(has("kind") | not)] | length
' "$PATHF")"

printf '[migrate-add-kind-field] backfilled kind="code" on %d items (remaining without kind: %d)\n' \
  "$MISSING_BEFORE" "$MISSING_AFTER"
