#!/usr/bin/env bash
# scripts/scrum/consolidate-improvements.sh — the 3-Sprint consolidation pass
# over .scrum/improvements.json.
#
# Usage:
#   consolidate-improvements.sh \
#     --sprint <sprint-id> \
#     [--archive imp-NNNN]...
#
# The Retrospective ceremony decides WHICH active entries are stale
# (addressed, obsolete, superseded); this wrapper only executes that
# decision: it flips each named entry to status=archived with an
# archived_at stamp, and bumps last_consolidation_sprint to <sprint-id>
# — in one atomic, schema-validated write. Zero --archive flags is
# valid: it records "consolidation reviewed, nothing stale" by bumping
# the marker alone.
#
# Idempotent on retry: an --archive id that is already archived is
# skipped with a WARN instead of failing, so a re-run after a partial
# ceremony never errors. An id that does not exist at all is a hard
# error (typo guard).
#
# Schema: docs/contracts/scrum-state/improvements.schema.json.
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
ARCHIVE_IDS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sprint)  SPRINT="$2"; shift 2 ;;
    --archive)
      # Zero-padded to at least 4 digits; grows past imp-9999 (matches schema).
      printf '%s' "$2" | grep -Eq '^imp-[0-9]{4,}$' \
        || fail E_INVALID_ARG "bad --archive: $2 (expected imp-NNNN)"
      ARCHIVE_IDS+=("$2")
      shift 2
      ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$SPRINT" ] || fail E_INVALID_ARG "--sprint required"
assert_sprint_id "$SPRINT" --sprint

PATHF=".scrum/improvements.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/improvements.schema.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF (nothing to consolidate — run append-improvement.sh first)"

# Pre-validate every id: unknown id is a hard error; already-archived is
# skipped (idempotent retry). Build the effective id set for the write.
EFFECTIVE_IDS=()
if [ "${#ARCHIVE_IDS[@]}" -gt 0 ]; then
  for id in "${ARCHIVE_IDS[@]}"; do
    st="$(jq -r --arg id "$id" '.entries[] | select(.id == $id) | .status' "$PATHF")"
    case "$st" in
      "")       fail E_INVALID_ARG "no such improvement entry: $id" ;;
      archived) printf '[consolidate-improvements] WARN: %s already archived — skipping\n' "$id" >&2 ;;
      *)        EFFECTIVE_IDS+=("$id") ;;
    esac
  done
fi

# Ids are pattern-validated above (imp-NNNN only), so embedding the JSON
# array literally into the jq expression is injection-safe — atomic_write
# only threads --arg now into the expression.
if [ "${#EFFECTIVE_IDS[@]}" -gt 0 ]; then
  IDS_JSON="$(printf '%s\n' "${EFFECTIVE_IDS[@]}" | jq -R . | jq -cs .)"
else
  IDS_JSON="[]"
fi

EXPR=".entries |= map(
        if (.id as \$i | $IDS_JSON | index(\$i)) != null
        then .status = \"archived\" | .archived_at = \$now
        else . end
      )
      | .last_consolidation_sprint = \"$SPRINT\""

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

printf '[consolidate-improvements] archived %d entrie(s); last_consolidation_sprint=%s\n' \
  "${#EFFECTIVE_IDS[@]}" "$SPRINT"
