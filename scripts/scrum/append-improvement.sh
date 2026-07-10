#!/usr/bin/env bash
# scripts/scrum/append-improvement.sh — append one entry to .scrum/improvements.json.
#
# Usage:
#   append-improvement.sh \
#     --sprint <sprint-id> \
#     --description <text> \
#     [--dec-id <dec-NNNN>]
#
# The improvement log is the Sprint Retrospective backlog. It is append-only
# from this wrapper's perspective: ids are auto-assigned (imp-NNNN,
# monotonically increasing) and existing entries are never rewritten. The
# 3-Sprint consolidation pass (status: archived, archived_at, last_consolidation_sprint
# bump) is a separate operation handled by consolidate-improvements.sh.
#
# Schema: docs/contracts/scrum-state/improvements.schema.json.
#
# The store file is created on first call (initial content
# `{"entries": [], "last_consolidation_sprint": null}`) and the parent
# directory `.scrum/` is created automatically.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

SPRINT=""
DESCRIPTION=""
DEC_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sprint)      SPRINT="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --dec-id)      DEC_ID="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$SPRINT" ]      || fail E_INVALID_ARG "--sprint required"
[ -n "$DESCRIPTION" ] || fail E_INVALID_ARG "--description required"

assert_sprint_id "$SPRINT" --sprint

if [ -n "$DEC_ID" ]; then
  case "$DEC_ID" in
    dec-[0-9][0-9][0-9][0-9]) ;;
    *) fail E_INVALID_ARG "bad --dec-id: $DEC_ID (expected dec-NNNN)" ;;
  esac
fi

PATHF=".scrum/improvements.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/improvements.schema.json"
mkdir -p "$(dirname "$PATHF")"
if [ ! -f "$PATHF" ]; then
  printf '%s\n' '{"entries": [], "last_consolidation_sprint": null}' > "$PATHF"
fi

# Compute next id (max imp-NNNN + 1, zero-padded to 4). jq returns 0 when the
# array is empty, so the first record is imp-0001.
NEXT_ID="$(alloc_next_id "$PATHF" '.entries' 'imp-' 4)"

# Build record JSON via jq -n so all free-form text is properly escaped.
REC_JSON="$(
  jq -n \
    --arg id "$NEXT_ID" \
    --arg sprint "$SPRINT" \
    --arg description "$DESCRIPTION" \
    --arg created_at "$(_iso_utc_now)" \
    --arg dec_id "$DEC_ID" \
    '{
      id: $id,
      sprint_id: $sprint,
      description: $description,
      status: "active",
      created_at: $created_at,
      archived_at: null
    }
    + (if $dec_id == "" then {} else {dec_id: $dec_id} end)'
)"

EXPR=".entries += [$REC_JSON]"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

# Echo the assigned id on stdout for callers that need to reference the record.
printf '%s\n' "$NEXT_ID"
