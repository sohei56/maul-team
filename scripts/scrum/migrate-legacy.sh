#!/usr/bin/env bash
# migrate-legacy.sh — convert pre-SSOT .scrum/*.json to current schema.
#
# Targets the artifacts the dashboard reads at top level:
#   .scrum/backlog.json   — rename .pbis -> .items, lowercase ids, drop unknown
#                           fields, remap legacy 6-value status to 13-value enum
#   .scrum/sprint.json    — lowercase pbi_ids, ensure started_at, lowercase
#                           per-dev refs
#   .scrum/state.json     — rename current_sprint -> current_sprint_id, remap
#                           legacy phase values (design / implementation ->
#                           pbi_pipeline_active), normalize dates
#
# Per-PBI files (.scrum/pbi/*/state.json) are NOT rewritten: their schema is
# strict and projects in flight legitimately carry richer fields. The legacy
# pbi-state.json `phase` field was removed in v2 — readers consult
# backlog.json.items[].status (13-value SSOT) instead.
#
# WARNING: status migration here is best-effort phase-blind remap. v1
# `in_progress` collapses to `in_progress_design`; v1 `review` collapses to
# `awaiting_cross_review`. Manual review of any in-flight PBIs is recommended
# before relying on the migrated state. This script is the sole v1 -> v2 path.
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
# shellcheck source=lib/errors.sh
source "$SCRIPT_DIR/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$SCRIPT_DIR/lib/atomic.sh"

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
[ -n "$SCHEMA_DIR" ] || fail E_FILE_MISSING \
  "scrum-state schemas not found (looked beside this script and under \$PWD/docs/contracts/scrum-state)"

if [ ! -d "$SCRUM_DIR" ]; then
  echo "No .scrum/ directory in $PWD — nothing to migrate."
  exit 0
fi

NOW="$(_iso_utc_now)"

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

# apply_migration_with_args <path> <jq_expr> <schema_path> [jq_extra_args...]
# Extra args are forwarded to both jq invocations (e.g. --arg name value).
# Use this when the migration expression references jq variables.
apply_migration_with_args() {
  local path="$1" expr="$2" schema="$3"
  shift 3

  if [ ! -f "$path" ]; then
    echo "  skip: $path (not present)"
    return 0
  fi

  local before after
  before="$(jq -S "$@" . "$path")"
  if ! after="$(jq -S "$@" "$expr" "$path" 2>&1)"; then
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

  local tmp; tmp="$(_make_tmp_path "$path")"
  printf '%s\n' "$after" > "$tmp"

  local err
  if err="$(_validate_against_schema "$tmp" "$schema" 2>&1)"; then
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
printf 'WARNING: for status migration after v1 -> v2, use this script carefully — phase-blind remap is best-effort. Manual review of any in_progress PBIs is recommended.\n' >&2

# --- backlog.json ---
# Rename .pbis -> .items, lowercase PBI ids, lowercase depends_on refs,
# drop fields the schema does not allow (additionalProperties: false on items),
# and remap legacy 6-value status to the 13-value enum (best-effort —
# without phase context, in_progress maps to in_progress_design and
# review maps to awaiting_cross_review). See WARNING above: manual review
# of any in_progress PBIs after migration is recommended.
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
apply_migration_with_args "$SCRUM_DIR/backlog.json" "$BACKLOG_EXPR" "$SCHEMA_DIR/backlog.schema.json" || true

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
apply_migration_with_args \
  "$SCRUM_DIR/sprint.json" "$SPRINT_EXPR" "$SCHEMA_DIR/sprint.schema.json" \
  --arg now "$NOW" \
  || true

# --- state.json ---
# Rename .current_sprint -> .current_sprint_id (preserving null), remap legacy
# phase values (design / implementation -> pbi_pipeline_active; both were
# removed from the v2 enum), normalize created_at / updated_at if they are
# date-only strings.
STATE_EXPR='
  (if has("current_sprint")
   then (.current_sprint_id //= .current_sprint) | del(.current_sprint)
   else . end)
  | (if (.phase == "design" or .phase == "implementation")
     then .phase = "pbi_pipeline_active"
     else . end)
  | (if (.created_at // "" | type) == "string" and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
     then .created_at += "T00:00:00Z" else . end)
  | (if (.updated_at // "" | type) == "string" and (.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
     then .updated_at += "T00:00:00Z" else . end)
'
apply_migration_with_args "$SCRUM_DIR/state.json" "$STATE_EXPR" "$SCHEMA_DIR/state.schema.json" || true

# --- legacy lock root ---
# Lock roots were unified on .scrum/locks/ (OD-6a); the old wrapper lock
# root .scrum/.locks/ is obsolete. Locks are transient, so anything left
# in the legacy dir can only be stale — remove the dir if present.
if [ -d "$SCRUM_DIR/.locks" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "  would remove legacy lock root: $SCRUM_DIR/.locks (dry-run)"
  else
    rm -rf "$SCRUM_DIR/.locks"
    echo "  removed legacy lock root: $SCRUM_DIR/.locks"
  fi
else
  echo "  ok: no legacy lock root ($SCRUM_DIR/.locks absent)"
fi

echo ""
echo "Migration done. Backups saved as <name>.legacy.bak alongside each migrated file."
