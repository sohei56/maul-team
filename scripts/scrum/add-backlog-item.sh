#!/usr/bin/env bash
# scripts/scrum/add-backlog-item.sh — append a new draft PBI to .scrum/backlog.json.
# Usage:
#   add-backlog-item.sh \
#     --title <text> \
#     [--description <text>] \
#     [--ac <criterion>]... \
#     [--parent <pbi-id>] \
#     [--ux-change] \
#     [--kind {code|docs}] \
#     [--audit-identity <defect-class>::<pattern>] \
#     [--audit-severity {critical|high|low}]
#
# `--audit-identity` is the cross-Sprint dedup key for codebase-audit PBIs and
# is REQUIRED when the title starts with "[codebase-audit:". It must be two
# lower-kebab parts joined by "::" — never a file path or line number, both of
# which drift under refactoring and silently mint a new defect class.
#
# `--audit-severity` is likewise REQUIRED for a "[codebase-audit:*" title and
# must agree case-insensitively with the title's 4th colon segment (the
# ":<Severity>]" suffix). The FIELD is canonical — the suffix is a
# human-scannable snapshot — so the two are pinned together here rather than
# by prompt discipline: the severity has one machine consumer (the
# Integration-entry block predicate) and a drifting title would silently
# mis-report it.
#
# Allocates the new id from `.next_pbi_id` (incremented post-write) and falls
# back to `max(items[].id) + 1` when the field is missing. Status is hardcoded
# to "draft" — Sprint Review and similar ceremonies create unrefined items
# that flow through Backlog Refinement → Sprint Planning. Prints the
# allocated pbi-id (e.g. "pbi-007") to stdout on success.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

TITLE=""
DESC=""
PARENT=""
UX_CHANGE="false"
KIND="code"
AUDIT_IDENTITY=""
AUDIT_SEVERITY=""
ACS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)           TITLE="$2"; shift 2 ;;
    --description)     DESC="$2"; shift 2 ;;
    --parent)          PARENT="$2"; shift 2 ;;
    --ac)              ACS+=("$2"); shift 2 ;;
    --ux-change)       UX_CHANGE="true"; shift 1 ;;
    --kind)            KIND="$2"; shift 2 ;;
    --audit-identity)  AUDIT_IDENTITY="$2"; shift 2 ;;
    --audit-severity)  AUDIT_SEVERITY="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$TITLE" ] || fail E_INVALID_ARG "--title required"

PATHF=".scrum/backlog.json"
# Resolved before the guards below because the audit-severity check derives its
# allow-list from the schema rather than hardcoding a parallel copy.
SCHEMA="$(resolve_schema_dir)/backlog.schema.json"

case "$KIND" in
  code|docs) ;;
  *) fail E_INVALID_ARG "bad --kind: $KIND (allowed: code, docs)" ;;
esac

# Audit PBIs carry the cross-Sprint dedup key as a first-class field. Enforced
# here rather than by prompt discipline: the identity line is dropped by whole
# audit axes often enough that the machine has to be the one that insists.
if [ -n "$AUDIT_IDENTITY" ]; then
  assert_audit_identity "$AUDIT_IDENTITY" --audit-identity
fi
if [ -n "$AUDIT_SEVERITY" ]; then
  backlog_audit_severity_enum "$SCHEMA" | grep -Fxq "$AUDIT_SEVERITY" || fail E_INVALID_ARG \
    "bad --audit-severity: $AUDIT_SEVERITY (allowed: $(backlog_audit_severity_enum "$SCHEMA" | tr '\n' ' ' | sed 's/ $//'))"
fi
case "$TITLE" in
  '[codebase-audit:'*)
    [ -n "$AUDIT_IDENTITY" ] || fail E_INVALID_ARG \
      "--audit-identity required for a [codebase-audit:*] PBI (the cross-Sprint dedup key; form: <defect-class>::<pattern>, lower kebab, no paths or line numbers)"
    [ -n "$AUDIT_SEVERITY" ] || fail E_INVALID_ARG \
      "--audit-severity required for a [codebase-audit:*] PBI (critical|high|low; the field is canonical and the title's :<Severity>] suffix is only a snapshot of it)"
    # Segments before the first "]" are exactly
    # codebase-audit : <sprint-id> : F<n>|DOCS : <Severity>.
    TITLE_SEV="$(printf '%s' "${TITLE%%]*}" | cut -d: -f4)"
    [ -n "$TITLE_SEV" ] || fail E_INVALID_ARG \
      "[codebase-audit:*] title carries no severity suffix: $TITLE (expected [codebase-audit:<sprint-id>:F<n>:<Severity>])"
    if [ "$(printf '%s' "$TITLE_SEV" | tr '[:upper:]' '[:lower:]')" != "$AUDIT_SEVERITY" ]; then
      fail E_INVALID_ARG \
        "title severity '$TITLE_SEV' disagrees with --audit-severity '$AUDIT_SEVERITY' (they must match case-insensitively)"
    fi
    ;;
esac

if [ -n "$PARENT" ]; then
  assert_pbi_id "$PARENT" --parent
fi

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
    --arg aid "$AUDIT_IDENTITY" \
    --arg asev "$AUDIT_SEVERITY" \
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
      demo_plan: null,
      kind: $kind,
      audit_identity: (if $aid == "" then null else $aid end),
      audit_severity: (if $asev == "" then null else $asev end),
      parent_pbi_id: (if $parent == "" then null else $parent end),
      created_at: $now,
      updated_at: $now
    }'
)"

EXPR=".items += [$NEW_ITEM_JSON] | .next_pbi_id = $INCREMENTED"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

printf '%s\n' "$NEW_ID"
