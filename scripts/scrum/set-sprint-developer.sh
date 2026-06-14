#!/usr/bin/env bash
# scripts/scrum/set-sprint-developer.sh — set a developer's field in .scrum/sprint.json.
# Usage: set-sprint-developer.sh <dev-id> <field> <value>
#
# Mutates one field on the developer with matching id, creating the entry if absent.
# Supported fields:
#   status          active|failed
#   current_pbi     pbi-NNN | null
#   assigned_work   JSON object: {"implement":["pbi-001","pbi-002",...]}
#                   (writes the whole assigned_work object; the schema
#                   forbids unknown sub-keys so callers must include the
#                   full intended shape every call). Used by
#                   spawn-teammates when seeding the per-Developer PBI
#                   allocation at Sprint start.
#   sub_agents      JSON array of strings
#                   (the deployed-sub-agent list maintained by
#                   install-subagents). Schema requires only "array";
#                   the wrapper additionally checks each element is a
#                   string.
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
  assigned_work)
    if ! VALUE_JSON="$(printf '%s' "$VALUE" | jq -ce '.')"; then
      fail E_INVALID_ARG "assigned_work: not valid JSON: $VALUE"
    fi
    if ! printf '%s' "$VALUE_JSON" | jq -e '
      type == "object"
      and ((.implement // []) | type == "array")
      and all(.implement[]?; type == "string" and test("^pbi-[0-9]+$"))
    ' >/dev/null; then
      fail E_INVALID_ARG "assigned_work: must be object with implement: array of pbi-NNN"
    fi
    ;;
  sub_agents)
    if ! VALUE_JSON="$(printf '%s' "$VALUE" | jq -ce '.')"; then
      fail E_INVALID_ARG "sub_agents: not valid JSON: $VALUE"
    fi
    if ! printf '%s' "$VALUE_JSON" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null; then
      fail E_INVALID_ARG "sub_agents: must be a JSON array of strings"
    fi
    ;;
  *) fail E_INVALID_ARG "unknown field: $FIELD (expected status|current_pbi|assigned_work|sub_agents)" ;;
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
