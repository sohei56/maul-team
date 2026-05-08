#!/usr/bin/env bash
# scripts/scrum/set-backlog-item-field.sh — set one schema-allowed field on
# `.scrum/backlog.json` items[]. Status is **not** writable here — it has its
# own dedicated wrapper (`update-backlog-status.sh`) because the 12-value enum
# governs lifecycle and validation.
#
# Usage:
#   set-backlog-item-field.sh <pbi-id> sprint_id <sprint-NNN|null>
#   set-backlog-item-field.sh <pbi-id> implementer_id <dev-NNN-sN|null>
#   set-backlog-item-field.sh <pbi-id> review_doc_path <path|null>
#   set-backlog-item-field.sh <pbi-id> catalog_targets <json-array>
#   set-backlog-item-field.sh <pbi-id> priority <non-negative-integer|null>
#
# `catalog_targets` takes a JSON string literal (e.g.
# '["docs/design/specs/foo.md","docs/design/specs/bar.md"]'); the wrapper
# validates it parses as an array of strings before applying.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 3 ] || fail E_INVALID_ARG "usage: set-backlog-item-field.sh <pbi-id> <field> <value>"
PBI="$1"; FIELD="$2"; VALUE="$3"

case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

# Validate field + value, build JSON literal for the value.
case "$FIELD" in
  sprint_id)
    case "$VALUE" in
      null)             VALUE_JSON="null" ;;
      sprint-[0-9]*)    VALUE_JSON="\"$VALUE\"" ;;
      *) fail E_INVALID_ARG "bad sprint_id: $VALUE (expected sprint-NNN or null)" ;;
    esac
    ;;
  implementer_id)
    case "$VALUE" in
      null)                          VALUE_JSON="null" ;;
      dev-[0-9]*-s[0-9]*)            VALUE_JSON="\"$VALUE\"" ;;
      *) fail E_INVALID_ARG "bad implementer_id: $VALUE (expected dev-NNN-sN or null)" ;;
    esac
    ;;
  review_doc_path)
    if [ "$VALUE" = "null" ]; then
      VALUE_JSON="null"
    else
      # JSON-encode arbitrary string via jq (handles quotes, backslashes, control chars).
      VALUE_JSON="$(printf '%s' "$VALUE" | jq -Rs .)"
    fi
    ;;
  catalog_targets)
    # Parse as JSON, require an array of strings (schema also enforces uniqueItems).
    if ! VALUE_JSON="$(printf '%s' "$VALUE" | jq -ce '.')"; then
      fail E_INVALID_ARG "catalog_targets: not valid JSON: $VALUE"
    fi
    if ! printf '%s' "$VALUE_JSON" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null; then
      fail E_INVALID_ARG "catalog_targets: must be a JSON array of strings"
    fi
    ;;
  priority)
    case "$VALUE" in
      null)              VALUE_JSON="null" ;;
      ''|*[!0-9]*)       fail E_INVALID_ARG "bad priority: $VALUE (expected non-negative integer or null)" ;;
      *)                 VALUE_JSON="$VALUE" ;;
    esac
    ;;
  status)
    fail E_INVALID_ARG "use update-backlog-status.sh to write status (12-value enum has its own wrapper)"
    ;;
  *) fail E_INVALID_ARG "unknown field: $FIELD (expected sprint_id|implementer_id|review_doc_path|catalog_targets|priority)" ;;
esac

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF"

# Pre-check the pbi exists (atomic_write cannot return "not found" by itself).
jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$PATHF" >/dev/null \
  || fail E_INVALID_ARG "pbi not found: $PBI"

# PBI and FIELD have passed strict whitelist case patterns above; VALUE_JSON is
# either a fixed literal (`null`), a JSON-quoted string built via jq -Rs, or a
# jq-parsed compact JSON string. Direct interpolation here is safe.
EXPR='(.items[] | select(.id == "'"$PBI"'")).'"$FIELD"' = '"$VALUE_JSON"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"
