#!/usr/bin/env bash
# migrate-legacy.sh — convert pre-SSOT .scrum/*.json to current schema.
#
# Targets the artifacts the dashboard reads at top level:
#   .scrum/backlog.json   — rename .pbis -> .items, lowercase ids, drop unknown fields
#   .scrum/sprint.json    — lowercase pbi_ids, ensure started_at, lowercase per-dev refs
#   .scrum/state.json     — rename current_sprint -> current_sprint_id, normalize dates
#
# Per-PBI files (.scrum/pbi/*/state.json) are NOT rewritten: their schema is
# strict and projects in flight legitimately carry richer fields. The dashboard
# pipeline pane already tolerates legacy phase vocab via PBI_STATE_PHASE_NORMALIZE.
#
# Idempotent: a second run reports "already canonical".
# Usage: scripts/scrum/migrate-legacy.sh [--dry-run]
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  "")           : ;;
  *)            echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

SCRUM_DIR=".scrum"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Locate scrum-state schemas. Try the source repo layout and the target
# project layout (where setup-user.sh copies them).
SCHEMA_DIR=""
for candidate in \
  "$SCRIPT_DIR/../../docs/contracts/scrum-state" \
  "$PWD/docs/contracts/scrum-state"; do
  if [ -d "$candidate" ]; then
    SCHEMA_DIR="$(cd "$candidate" && pwd)"
    break
  fi
done
if [ -z "$SCHEMA_DIR" ]; then
  echo "Error: scrum-state schemas not found (looked beside this script and under \$PWD/docs/contracts/scrum-state)" >&2
  exit 67
fi

if [ ! -d "$SCRUM_DIR" ]; then
  echo "No .scrum/ directory in $PWD — nothing to migrate."
  exit 0
fi

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
NOW="$(iso_now)"

# _diff_strings <a> <b>
# Print a unified diff of two strings without bash/POSIX process substitution
# (so the script parses cleanly under /bin/sh on macOS).
_diff_strings() {
  local a="$1" b="$2"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/scrum-migrate.XXXXXX")"
  printf '%s\n' "$a" > "$d/before"
  printf '%s\n' "$b" > "$d/after"
  diff -u "$d/before" "$d/after" | head -30 || true
  rm -rf "$d"
}

# validate_json <json_path> <schema_path>
# Uses python3+jsonschema. Returns 0 on valid, prints error to stderr otherwise.
validate_json() {
  local json_path="$1" schema_path="$2"
  python3 - "$json_path" "$schema_path" <<'PY' 2>&1
import json, sys
try:
    import jsonschema
except ImportError:
    print("jsonschema package missing; install with: pip install jsonschema", file=sys.stderr)
    sys.exit(2)
json_path, schema_path = sys.argv[1], sys.argv[2]
data = json.load(open(json_path))
schema = json.load(open(schema_path))
try:
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as exc:
    print(f"validation error: {exc.message}", file=sys.stderr)
    sys.exit(1)
PY
}

# apply_migration <path> <jq_expr> <schema_path>
apply_migration() {
  local path="$1" expr="$2" schema="$3"
  if [ ! -f "$path" ]; then
    echo "  skip: $path (not present)"
    return 0
  fi

  local before after
  before="$(jq -S . "$path")"
  if ! after="$(jq -S "$expr" "$path" 2>&1)"; then
    echo "  ERROR: jq failed on $path: $after" >&2
    return 1
  fi

  if [ "$before" = "$after" ]; then
    echo "  ok: $path (already canonical)"
    return 0
  fi

  echo "  migrate: $path"
  if [ "$DRY_RUN" = 1 ]; then
    _diff_strings "$before" "$after"
    echo "    (dry-run; no file written)"
    return 0
  fi

  local tmp="${path}.tmp.$$"
  printf '%s\n' "$after" > "$tmp"

  local err
  if err="$(validate_json "$tmp" "$schema")"; then
    cp "$path" "${path}.legacy.bak"
    mv "$tmp" "$path"
    echo "    -> migrated (.legacy.bak saved)"
  else
    rm -f "$tmp"
    echo "    -> validation FAILED, original left untouched: $err" >&2
    return 1
  fi
}

echo "Migrating $SCRUM_DIR (schemas: $SCHEMA_DIR)..."
[ "$DRY_RUN" = 1 ] && echo "  (dry-run)"

# --- backlog.json ---
# Rename .pbis -> .items, lowercase PBI ids, lowercase depends_on refs,
# drop fields the schema does not allow (additionalProperties: false on items),
# and remap legacy 6-value status to the 12-value enum (best-effort —
# without phase context, in_progress maps to in_progress_design and
# review maps to awaiting_cross_review; PBI-G's migrate-status-v2.sh
# does the precise phase-aware mapping when pbi-state.json is available).
BACKLOG_EXPR='
  (if has("pbis") then .items = .pbis | del(.pbis) else . end)
  | .items |= ((. // []) | map(
      .id |= ascii_downcase
      | (if has("depends_on_pbi_ids")
         then .depends_on_pbi_ids |= map(ascii_downcase)
         else . end)
      | del(.estimated_points)
      | del(.reviewer_id)
      | (if .status == "in_progress" then .status = "in_progress_design"
         elif .status == "review"    then .status = "awaiting_cross_review"
         else . end)
    ))
'
apply_migration "$SCRUM_DIR/backlog.json" "$BACKLOG_EXPR" "$SCHEMA_DIR/backlog.schema.json" || true

# --- sprint.json ---
# Lowercase pbi_ids[] and per-developer assigned_work.implement refs. Drop
# legacy assigned_work.review (peer-review model removed). Ensure started_at
# (schema requires it; legacy files only have created_at).
# shellcheck disable=SC2016  # $now is a jq variable bound below via --arg
SPRINT_EXPR='
  (if has("pbi_ids") then .pbi_ids |= map(ascii_downcase) else . end)
  | (if has("developers")
     then .developers |= map(
       (if (.assigned_work // null) != null
        then .assigned_work.implement |= ((. // []) | map(ascii_downcase))
             | del(.assigned_work.review)
        else . end)
       | (if (.current_pbi // null) != null
          then .current_pbi |= ascii_downcase
          else . end)
     )
     else . end)
  | (if has("started_at")
     then .
     else .started_at = (
       (.created_at // $now)
       | (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end)
     )
     end)
'
if [ -f "$SCRUM_DIR/sprint.json" ]; then
  before="$(jq -S . "$SCRUM_DIR/sprint.json")"
  after="$(jq -S --arg now "$NOW" "$SPRINT_EXPR" "$SCRUM_DIR/sprint.json")"
  if [ "$before" = "$after" ]; then
    echo "  ok: $SCRUM_DIR/sprint.json (already canonical)"
  else
    echo "  migrate: $SCRUM_DIR/sprint.json"
    if [ "$DRY_RUN" = 1 ]; then
      _diff_strings "$before" "$after"
      echo "    (dry-run; no file written)"
    else
      tmp="$SCRUM_DIR/sprint.json.tmp.$$"
      printf '%s\n' "$after" > "$tmp"
      if err="$(validate_json "$tmp" "$SCHEMA_DIR/sprint.schema.json")"; then
        cp "$SCRUM_DIR/sprint.json" "$SCRUM_DIR/sprint.json.legacy.bak"
        mv "$tmp" "$SCRUM_DIR/sprint.json"
        echo "    -> migrated (.legacy.bak saved)"
      else
        rm -f "$tmp"
        echo "    -> validation FAILED, original left untouched: $err" >&2
      fi
    fi
  fi
else
  echo "  skip: $SCRUM_DIR/sprint.json (not present)"
fi

# --- state.json ---
# Rename .current_sprint -> .current_sprint_id (preserving null), normalize
# created_at / updated_at if they are date-only strings.
STATE_EXPR='
  (if has("current_sprint")
   then (.current_sprint_id //= .current_sprint) | del(.current_sprint)
   else . end)
  | (if (.created_at // "" | type) == "string" and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
     then .created_at += "T00:00:00Z" else . end)
  | (if (.updated_at // "" | type) == "string" and (.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
     then .updated_at += "T00:00:00Z" else . end)
'
apply_migration "$SCRUM_DIR/state.json" "$STATE_EXPR" "$SCHEMA_DIR/state.schema.json" || true

echo ""
echo "Migration done. Backups saved as <name>.legacy.bak alongside each migrated file."
