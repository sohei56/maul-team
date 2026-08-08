#!/usr/bin/env bash
# migrations/006-add-audit-severity.sh — back-fill the first-class
# `audit_severity` field on codebase-audit PBIs from the title's
# ":<Severity>]" suffix. Idempotent: a second run is a no-op.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated writes,
# missing files are a clean no-op).
#
# Why: severity used to live only inside the title string, where its single
# machine consumer — the Integration-entry block predicate — had to parse it
# back out with a regex. The predicate is now `audit_severity != "low"`, so an
# unkeyed legacy PBI needs the back-fill to be rated at all.
#
# Map: Critical→critical, High→high, Medium→high, Low→low; anything else is
# left unset. `Medium→high` is the semantically faithful map, not merely the
# conservative one — the retired Medium row ("dead code / unused export, an
# edge-case gap on a secondary path, or a stale docstring that actively
# misleads") is squarely the new High ("the spec is met but leaving it unfixed
# causes future harm"). The error direction agrees: medium→low would silently
# drop those PBIs OUT of the block set (an invisible failure), while
# medium→high adds them (a visible one the PO can clear with a single
# reject/cancel).
#
# BEHAVIOR CHANGE: in a target that currently has open `Medium` audit PBIs,
# this migration turns a previously-passing Integration-Sprint entry into a
# block. That is correct under the three-level definitions, but it is a runtime
# behavior change delivered by a migration.
#
# Unparseable suffixes stay null and are reported — the same discipline as 005
# (never invent a key a machine cannot derive). Safe because the block
# predicate is fail-safe: `(.audit_severity // "high") != "low"` blocks on
# null.
#
# Usage: scripts/scrum/migrations/006-add-audit-severity.sh [--dry-run]
# Runs in the cwd against .scrum/backlog.json. Prints a one-line summary.
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  "")           : ;;
  *)            echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/errors.sh
source "$HERE/../lib/errors.sh"
# shellcheck source=../lib/atomic.sh
source "$HERE/../lib/atomic.sh"

PATHF=".scrum/backlog.json"

if [ ! -f "$PATHF" ]; then
  echo "[006-add-audit-severity] skip: $PATHF not present"
  exit 0
fi

# Candidates: audit-filed PBIs with no audit_severity yet.
CANDIDATES="$(jq '
  [ .items[]
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_severity // null) == null)
  ] | length
' "$PATHF")"

if [ "$CANDIDATES" -eq 0 ]; then
  printf '[006-add-audit-severity] no-op: every audit PBI already carries audit_severity\n'
  exit 0
fi

# The severity is the 4th colon segment before the first "]". The pattern is
# inlined rather than passed as a jq --arg because atomic_write binds only
# $now — it takes no extra jq arguments.
# shellcheck disable=SC2016  # $s is a jq binding, not a shell variable
EXPR='
  .items |= map(
    if ((.title // "") | startswith("[codebase-audit:"))
       and ((.audit_severity // null) == null)
    then
      ( (.title // "")
        | (capture("^\\[codebase-audit:[^:]*:[^:]*:(?<s>[^:\\]]+)\\]").s? // "")
        | ascii_downcase
      ) as $s
      | if   $s == "critical" then .audit_severity = "critical"
        elif $s == "high"     then .audit_severity = "high"
        elif $s == "medium"   then .audit_severity = "high"
        elif $s == "low"      then .audit_severity = "low"
        else . end
    else . end
  )
'

# Medium is the one mapping that changes the Integration-entry verdict, so it
# is counted separately in both the dry-run plan and the applied summary.
MEDIUM="$(jq '
  [ .items[]
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_severity // null) == null)
    | select((.title // "") | test("^\\[codebase-audit:[^:]*:[^:]*:[Mm]edium\\]"))
  ] | length
' "$PATHF")"

if [ "$DRY_RUN" = 1 ]; then
  HAVE_NOW="$(jq '[.items[] | select((.audit_severity // null) != null)] | length' "$PATHF")"
  WOULD="$(jq "[ ($EXPR | .items[]) | select((.audit_severity // null) != null) ] | length" "$PATHF")"
  printf '[006-add-audit-severity] would rate %d of %d unkeyed audit PBIs (%d medium→high) (dry-run; no file written)\n' \
    "$((WOULD - HAVE_NOW))" "$CANDIDATES" "$MEDIUM"
  exit 0
fi

# Shared source/deployed-layout probe (lib/atomic.sh). Resolved only on the
# write path so the no-op branches above stay schema-independent.
SCHEMA="$(resolve_schema_dir)/backlog.schema.json"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

REMAINING="$(jq '
  [ .items[]
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_severity // null) == null)
  ] | length
' "$PATHF")"
RATED=$((CANDIDATES - REMAINING))

printf '[006-add-audit-severity] rated %d audit PBIs (%d medium→high) — %d still unkeyed (unparseable title suffix; they block Integration entry until set, which is the fail-safe direction)\n' \
  "$RATED" "$MEDIUM" "$REMAINING"
