#!/usr/bin/env bash
# scripts/scrum/update-state-phase.sh — set top-level phase in .scrum/state.json.
# Usage: update-state-phase.sh <phase>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: update-state-phase.sh <phase>"
PHASE="$1"
case "$PHASE" in
  new|requirements_sprint|backlog_created|sprint_planning|pbi_pipeline_active|review|sprint_review|retrospective|integration_sprint|complete) ;;
  *) fail E_INVALID_ARG "bad phase: $PHASE" ;;
esac

atomic_write ".scrum/state.json" \
  ".phase = \"$PHASE\"" \
  "$ROOT/docs/contracts/scrum-state/state.schema.json"
