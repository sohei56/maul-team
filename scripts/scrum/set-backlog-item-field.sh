#!/usr/bin/env bash
# scripts/scrum/set-backlog-item-field.sh — set one schema-allowed field on
# `.scrum/backlog.json` items[]. Status is **not** writable here — it has its
# own dedicated wrapper (`update-backlog-status.sh`) because the 13-value enum
# governs lifecycle and validation.
#
# Usage:
#   set-backlog-item-field.sh <pbi-id> sprint_id <sprint-NNN|null>
#   set-backlog-item-field.sh <pbi-id> implementer_id <dev-NNN-sN|null>
#   set-backlog-item-field.sh <pbi-id> review_doc_path <path|null>
#   set-backlog-item-field.sh <pbi-id> catalog_targets <json-array>
#   set-backlog-item-field.sh <pbi-id> priority <non-negative-integer|null>
#   set-backlog-item-field.sh <pbi-id> description <text|null>
#   set-backlog-item-field.sh <pbi-id> ux_change <true|false>
#   set-backlog-item-field.sh <pbi-id> acceptance_criteria <json-array-of-strings>
#   set-backlog-item-field.sh <pbi-id> design_doc_paths <json-array-of-strings>
#   set-backlog-item-field.sh <pbi-id> depends_on_pbi_ids <json-array-of-pbi-ids>
#   set-backlog-item-field.sh <pbi-id> kind <code|docs>
#
# `catalog_targets`, `acceptance_criteria`, `design_doc_paths`, and
# `depends_on_pbi_ids` all take JSON string literals (e.g.
# '["docs/design/specs/foo.md","docs/design/specs/bar.md"]'); the
# wrapper validates each parses as an array of strings (and, for
# `depends_on_pbi_ids`, that each element matches `pbi-NNN`).
#
# `description` accepts an arbitrary string or `null`; `ux_change`
# accepts only `true` / `false`. These are the fields the
# `backlog-refinement` skill needs to fill on the `draft → refined`
# transition — without them the schema's "refined PBIs have non-empty
# acceptance_criteria" expectation can't be satisfied through wrappers,
# and the PreToolUse guard blocks any direct edit of
# `.scrum/backlog.json`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 3 ] || fail E_INVALID_ARG "usage: set-backlog-item-field.sh <pbi-id> <field> <value>"
PBI="$1"; FIELD="$2"; VALUE="$3"

assert_pbi_id "$PBI"

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
  description)
    if [ "$VALUE" = "null" ]; then
      VALUE_JSON="null"
    else
      VALUE_JSON="$(printf '%s' "$VALUE" | jq -Rs .)"
    fi
    ;;
  ux_change)
    case "$VALUE" in
      true|false) VALUE_JSON="$VALUE" ;;
      *) fail E_INVALID_ARG "bad ux_change: $VALUE (expected true or false)" ;;
    esac
    ;;
  acceptance_criteria|design_doc_paths)
    if ! VALUE_JSON="$(printf '%s' "$VALUE" | jq -ce '.')"; then
      fail E_INVALID_ARG "$FIELD: not valid JSON: $VALUE"
    fi
    if ! printf '%s' "$VALUE_JSON" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null; then
      fail E_INVALID_ARG "$FIELD: must be a JSON array of strings"
    fi
    ;;
  depends_on_pbi_ids)
    if ! VALUE_JSON="$(printf '%s' "$VALUE" | jq -ce '.')"; then
      fail E_INVALID_ARG "depends_on_pbi_ids: not valid JSON: $VALUE"
    fi
    if ! printf '%s' "$VALUE_JSON" | jq -e 'type == "array" and all(.[]; type == "string" and test("^pbi-[0-9]+$"))' >/dev/null; then
      fail E_INVALID_ARG "depends_on_pbi_ids: must be a JSON array of pbi-NNN strings"
    fi
    ;;
  kind)
    case "$VALUE" in
      code|docs) VALUE_JSON="\"$VALUE\"" ;;
      *) fail E_INVALID_ARG "bad kind: $VALUE (expected code or docs)" ;;
    esac
    ;;
  status)
    fail E_INVALID_ARG "use update-backlog-status.sh to write status (13-value enum has its own wrapper)"
    ;;
  *) fail E_INVALID_ARG "unknown field: $FIELD (expected sprint_id|implementer_id|review_doc_path|catalog_targets|priority|description|ux_change|acceptance_criteria|design_doc_paths|depends_on_pbi_ids|kind)" ;;
esac

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF"

# Pre-check the pbi exists (atomic_write cannot return "not found" by itself).
pbi_in_backlog "$PBI" "$PATHF" || fail E_INVALID_ARG "pbi not found: $PBI"

# PBI and FIELD have passed strict whitelist case patterns above; VALUE_JSON is
# either a fixed literal (`null`), a JSON-quoted string built via jq -Rs, or a
# jq-parsed compact JSON string. Direct interpolation here is safe.
#
# updated_at is stamped alongside the field mutation. atomic_write's auto-touch
# only fires on a top-level updated_at (backlog.json has none), so the item's
# field is set explicitly. $now is bound by atomic_write via `--arg now` (same
# ISO-8601 UTC format add-backlog-item.sh seeds created_at/updated_at).
# shellcheck disable=SC2016  # $now is a jq var bound by atomic_write --arg now, not a shell var
EXPR='(.items[] | select(.id == "'"$PBI"'")) |= (.'"$FIELD"' = '"$VALUE_JSON"' | .updated_at = $now)'

atomic_write "$PATHF" "$EXPR" "$SCHEMA"
