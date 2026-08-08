#!/usr/bin/env bash
# migrations/005-add-audit-identity.sh — lift the codebase-audit cross-Sprint
# dedup key out of the PBI description free text into the first-class
# `audit_identity` field. Idempotent: a second run is a no-op.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated writes,
# missing files are a clean no-op).
#
# Why: the key used to live only inside `description` as "audit-id: <X>", where
# (a) the auditors that mint it cannot see it — the audit read set deliberately
# withholds descriptions, so every Sprint minted a fresh string for the same
# defect class, and (b) refinement may overwrite `description` wholesale, taking
# the key with it. Matching was a substring `contains`, so a one-character
# difference silently produced a duplicate PBI.
#
# Backfill rule: only lift keys that already satisfy the schema's normalized
# form (`<defect-class>::<pattern>`, lower kebab both sides). Legacy keys built
# from file paths or symbols are NOT rewritten — a machine cannot decide the
# semantic class name, and inventing a slug here would mint a key that no future
# audit will ever reproduce, which is the exact failure this field exists to
# stop. Those items keep an empty field and are reported in the summary: each
# one costs at most one duplicate filing on the next audit, after which the
# class is keyed correctly forever.
#
# Usage: scripts/scrum/migrations/005-add-audit-identity.sh [--dry-run]
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
  echo "[005-add-audit-identity] skip: $PATHF not present"
  exit 0
fi

# Candidates: audit-filed PBIs with no audit_identity yet whose description
# carries a legacy "audit-id: <X>" marker.
CANDIDATES="$(jq '
  [ .items[]
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_identity // null) == null)
    | select(((.description // "") | test("audit-id:[[:space:]]*[^[:space:].]+")))
  ] | length
' "$PATHF")"

if [ "$CANDIDATES" -eq 0 ]; then
  printf '[005-add-audit-identity] no-op: no audit PBIs carry a liftable audit-id marker\n'
  exit 0
fi

# Extract the marker, strip a trailing sentence period, and keep it only when it
# already matches the normalized two-part form the schema enforces. The pattern
# is inlined rather than passed as a jq --arg because atomic_write binds only
# $now — it takes no extra jq arguments.
# shellcheck disable=SC2016  # $k is a jq binding, not a shell variable
EXPR='
  .items |= map(
    if ((.title // "") | startswith("[codebase-audit:"))
       and ((.audit_identity // null) == null)
    then
      ( (.description // "")
        | (capture("audit-id:[[:space:]]*(?<k>[^[:space:]]+)").k? // "")
        | sub("\\.$"; "")
      ) as $k
      | if ($k | test("^[a-z0-9]+(-[a-z0-9]+)*::[a-z0-9]+(-[a-z0-9]+)*$"))
        then .audit_identity = $k
        else . end
    else . end
  )
'

if [ "$DRY_RUN" = 1 ]; then
  HAVE_NOW="$(jq '[.items[] | select((.audit_identity // null) != null)] | length' "$PATHF")"
  WOULD="$(jq "[ ($EXPR | .items[]) | select((.audit_identity // null) != null) ] | length" "$PATHF")"
  printf '[005-add-audit-identity] would lift %d of %d legacy audit-id markers into audit_identity (dry-run; no file written)\n' \
    "$((WOULD - HAVE_NOW))" "$CANDIDATES"
  exit 0
fi

# Shared source/deployed-layout probe (lib/atomic.sh). Resolved only on the
# write path so the no-op branches above stay schema-independent.
SCHEMA="$(resolve_schema_dir)/backlog.schema.json"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

REMAINING="$(jq '
  [ .items[]
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_identity // null) == null)
  ] | length
' "$PATHF")"
LIFTED=$((CANDIDATES - REMAINING))

printf '[005-add-audit-identity] lifted %d audit-id markers into audit_identity (%d audit PBIs still unkeyed — legacy path-shaped keys, each costs at most one duplicate filing on the next audit)\n' \
  "$LIFTED" "$REMAINING"
