#!/usr/bin/env bash
# scripts/scrum/set-sprint-developer.sh — set a developer's field in .scrum/sprint.json.
# Usage: set-sprint-developer.sh <dev-id> <field> <value>
#
# Mutates one field on the developer with matching id, creating the entry if absent.
# Supported fields: status, current_pbi.
# `null` value is accepted for current_pbi (becomes JSON null).
# (Per-Developer phase tracking removed — PBI lifecycle status lives in backlog.json.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 3 ] || fail E_INVALID_ARG "usage: set-sprint-developer.sh <dev-id> <field> <value>"
DEV="$1"; FIELD="$2"; VALUE="$3"

case "$DEV" in
  dev-[0-9]*-s[0-9]*) ;;
  *) fail E_INVALID_ARG "bad dev id: $DEV (expected dev-XXX-sN)" ;;
esac

# Validate field + value combinations and build the JSON literal for the value.
case "$FIELD" in
  status)
    case "$VALUE" in
      active|failed) ;;
      *) fail E_INVALID_ARG "bad status: $VALUE (expected active|failed)" ;;
    esac
    VALUE_JSON="\"$VALUE\""
    ;;
  current_pbi)
    case "$VALUE" in
      null) VALUE_JSON="null" ;;
      pbi-[0-9]*) VALUE_JSON="\"$VALUE\"" ;;
      *) fail E_INVALID_ARG "bad pbi-id: $VALUE (expected pbi-NNN or null)" ;;
    esac
    ;;
  *) fail E_INVALID_ARG "unknown field: $FIELD (expected status|current_pbi)" ;;
esac

# Determine the seed status for a fresh entry: if the field being set IS status,
# the seed status equals the new value; otherwise default to "active".
if [ "$FIELD" = "status" ]; then
  SEED_STATUS_JSON="$VALUE_JSON"
else
  SEED_STATUS_JSON='"active"'
fi

# All three values (DEV, FIELD, VALUE_JSON) have passed strict whitelist case
# patterns above, so direct interpolation here is safe (no shell injection risk).
EXPR='.developers |= (
  if any(.[]; .id == "'"$DEV"'")
  then map(if .id == "'"$DEV"'" then .'"$FIELD"' = '"$VALUE_JSON"' else . end)
  else . + [{id: "'"$DEV"'", status: '"$SEED_STATUS_JSON"', '"$FIELD"': '"$VALUE_JSON"'}]
  end
)'

atomic_write ".scrum/sprint.json" "$EXPR" "$ROOT/docs/contracts/scrum-state/sprint.schema.json"
