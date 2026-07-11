#!/usr/bin/env bash
# scripts/scrum/add-backlog-item.sh — append a new draft PBI to .scrum/backlog.json.
# Usage:
#   add-backlog-item.sh \
#     --title <text> \
#     [--description <text>] \
#     [--ac <criterion>]... \
#     [--parent <pbi-id>] \
#     [--ux-change] \
#     [--kind {code|docs}]
#
# Allocates the new id from `.next_pbi_id` (incremented post-write) and falls
# back to `max(items[].id) + 1` when the field is missing. Status is hardcoded
# to "draft" — Sprint Review and similar ceremonies create unrefined items
# that flow through Backlog Refinement → Sprint Planning. Prints the
# allocated pbi-id (e.g. "pbi-007") to stdout on success.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

TITLE=""
DESC=""
PARENT=""
UX_CHANGE="false"
KIND="code"
ACS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)        TITLE="$2"; shift 2 ;;
    --description)  DESC="$2"; shift 2 ;;
    --parent)       PARENT="$2"; shift 2 ;;
    --ac)           ACS+=("$2"); shift 2 ;;
    --ux-change)    UX_CHANGE="true"; shift 1 ;;
    --kind)         KIND="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$TITLE" ] || fail E_INVALID_ARG "--title required"

case "$KIND" in
  code|docs) ;;
  *) fail E_INVALID_ARG "bad --kind: $KIND (allowed: code, docs)" ;;
esac

if [ -n "$PARENT" ]; then
  assert_pbi_id "$PARENT" --parent
fi

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF"

# Allocate id. Prefer .next_pbi_id; fall back to max(items[].id)+1.
NEXT_NUM="$(jq -r '.next_pbi_id // empty' "$PATHF")"
if [ -z "$NEXT_NUM" ] || [ "$NEXT_NUM" = "null" ]; then
  NEXT_NUM="$(jq -r '
    [.items[]?.id | capture("^pbi-(?<n>[0-9]+)$").n | tonumber]
    | (max // 0) + 1
  ' "$PATHF")"
fi
case "$NEXT_NUM" in
  ''|*[!0-9]*) fail E_INVALID_ARG "could not allocate next pbi number (got: '$NEXT_NUM')" ;;
esac
NEW_ID="$(printf 'pbi-%03d' "$NEXT_NUM")"
INCREMENTED=$((NEXT_NUM + 1))

# Build acceptance_criteria JSON array. Keep bash 3.2 friendly.
if [ "${#ACS[@]}" -eq 0 ]; then
  AC_JSON='[]'
else
  AC_JSON="$(printf '%s\n' "${ACS[@]}" | json_lines_to_array)"
fi

NOW="$(_iso_utc_now)"

NEW_ITEM_JSON="$(
  jq -n \
    --arg id "$NEW_ID" \
    --arg title "$TITLE" \
    --arg desc "$DESC" \
    --arg parent "$PARENT" \
    --arg now "$NOW" \
    --arg kind "$KIND" \
    --argjson ac "$AC_JSON" \
    --argjson ux "$UX_CHANGE" \
    '{
      id: $id,
      title: $title,
      description: (if $desc == "" then null else $desc end),
      acceptance_criteria: $ac,
      status: "draft",
      priority: null,
      sprint_id: null,
      implementer_id: null,
      design_doc_paths: [],
      review_doc_path: null,
      depends_on_pbi_ids: [],
      ux_change: $ux,
      kind: $kind,
      parent_pbi_id: (if $parent == "" then null else $parent end),
      created_at: $now,
      updated_at: $now
    }'
)"

EXPR=".items += [$NEW_ITEM_JSON] | .next_pbi_id = $INCREMENTED"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

printf '%s\n' "$NEW_ID"
