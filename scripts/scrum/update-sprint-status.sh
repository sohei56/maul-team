#!/usr/bin/env bash
# scripts/scrum/update-sprint-status.sh — set status in .scrum/sprint.json.
# Usage: update-sprint-status.sh <status>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: update-sprint-status.sh <status>"
STATUS="$1"
case "$STATUS" in
  planning|active|cross_review|sprint_review|complete|failed) ;;
  *) fail E_INVALID_ARG "bad status: $STATUS" ;;
esac

# Stamp completed_at on terminal transitions so Sprint Review can read it
# from sprint.json (the schema declares completed_at: ISO 8601 | null and
# init-sprint.sh seeds null; without this stamp the field would stay null
# forever).
EXPR=".status = \"$STATUS\""
case "$STATUS" in
  complete|failed)
    NOW="$(_iso_utc_now)"
    EXPR="$EXPR | .completed_at = \"$NOW\""
    ;;
esac

atomic_write ".scrum/sprint.json" \
  "$EXPR" \
  "$ROOT/docs/contracts/scrum-state/sprint.schema.json"
