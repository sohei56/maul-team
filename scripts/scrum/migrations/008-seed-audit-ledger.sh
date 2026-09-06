#!/usr/bin/env bash
# migrations/008-seed-audit-ledger.sh — create `.scrum/audit-ledger.json` and
# seed one class per distinct `audit_identity` already carried by
# `[codebase-audit:*]` PBIs. Idempotent: a re-run merges newly-filed PBIs into
# existing classes and touches nothing else.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated writes,
# missing files are a clean no-op).
#
# Why the file is created even when there is nothing to seed: from this change
# on, `add-backlog-item.sh` requires an `--audit-identity` to name a class
# present in the ledger — but ONLY when the ledger exists, so a target that has
# never been migrated is not bricked. That bootstrap carve-out is only safe if
# every launched project actually gets a ledger, which is this migration's real
# job. A project with no backlog at all has not started and is skipped; it will
# get its ledger on the launch after `init-backlog.sh` runs.
#
# Seeding rules, and what is deliberately NOT invented:
#   - `occurrences: []` and `axis: []` — always. Prose descriptions cannot be
#     parsed into a stable `(path, symbol)` key, and a fabricated occurrence
#     set would make the "did the sweep shrink?" measurement lie from day one.
#     Same discipline as 005/006: never invent a key a machine cannot derive.
#   - `detector: null` — a detector must be registered through the wrapper,
#     which verifies it by running it. There is nothing to verify here.
#   - `severity` = the HIGHEST `audit_severity` among the class's PBIs, with
#     `// "high"` for an unrated one (the fail-safe already used at
#     codebase-audit SKILL.md's block predicate). Highest, not last, mirrors
#     the wrapper's monotonic raise: a class is as bad as its worst sighting.
#   - `first_seen_sprint` / `last_confirmed_sprint` = the earliest / latest
#     sprint id in the titles' 2nd colon segment
#     (`[codebase-audit:<sprint-id>:F<n>:<Sev>]`), falling back to
#     `sprint.json.id` when a title carries no parseable one. A class with
#     neither is SKIPPED and reported — `first_seen_sprint` is required by the
#     schema and there is nothing to derive it from.
#   - `pbi_ids` = every matching PBI with `role: sweep`. No pre-existing PBI
#     can have been a detector PBI: detectors did not exist before this change.
#
# Status matrix (linked PBIs of the class):
#   any item neither done nor cancelled  -> "open"
#   some done, none open                 -> "closed", with
#                                           closed_evidence naming this
#                                           migration as the source
#   otherwise (cancelled-only, or none)  -> "open"
# A cancelled-only class stays detectable on purpose: `cancelled` means
# descoped, not fixed, and codebase-audit treats it as not-open precisely so
# the class can be re-detected.
#
# Usage: scripts/scrum/migrations/008-seed-audit-ledger.sh [--dry-run]
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

BACKLOG=".scrum/backlog.json"
LEDGER=".scrum/audit-ledger.json"
SPRINT=".scrum/sprint.json"

if [ ! -f "$BACKLOG" ]; then
  echo "[008-seed-audit-ledger] skip: $BACKLOG not present"
  exit 0
fi

# Fallback sprint for titles with no parseable id. Empty when there is no
# current Sprint; classes that need it are then skipped and named.
FALLBACK_SPRINT="$(jq -r '.id // ""' "$SPRINT" 2>/dev/null || true)"
printf '%s' "$FALLBACK_SPRINT" | grep -Eq '^sprint-[0-9]+$' || FALLBACK_SPRINT=""

# One pass over the backlog, grouped by identity. Emits
# {seed: [<class>...], skipped: [<identity>...]}; `skipped` holds the classes
# whose sprint could not be derived at all.
# shellcheck disable=SC2016  # $fb/$g/$sprints are jq bindings, not shell variables
CLASS_GROUPS="$(jq -c --arg fb "$FALLBACK_SPRINT" '
  def sevrank: if . == "critical" then 3 elif . == "high" then 2 elif . == "low" then 1 else 0 end;
  def sprintnum: (capture("^sprint-(?<n>[0-9]+)$").n | tonumber);
  [ .items[]?
    | select((.title // "") | startswith("[codebase-audit:"))
    | select((.audit_identity // null) != null)
    | { identity: .audit_identity,
        id: .id,
        status: (.status // ""),
        severity: (.audit_severity // "high"),
        sprint: (((.title // "")
                  | capture("^\\[codebase-audit:(?<s>sprint-[0-9]+):").s?) // $fb) }
  ]
  | group_by(.identity)
  | map({ identity: .[0].identity,
          rows: . })
  | map(. + { sprints: [ .rows[].sprint | select(. != null and . != "") ] })
  | { seed: [ .[]
              | select((.sprints | length) > 0)
              | . as $g
              | (if ([ $g.rows[] | select(.status != "done" and .status != "cancelled") ] | length) > 0
                 then "open"
                 elif ([ $g.rows[] | select(.status == "done") ] | length) > 0
                 then "closed"
                 else "open" end) as $st
              | { identity: $g.identity,
                  axis: [],
                  severity: ([ $g.rows[].severity ] | max_by(sevrank)),
                  status: $st,
                  occurrences: [],
                  exclusions: [],
                  detector: null,
                  pbi_ids: [ $g.rows[] | { id: .id, role: "sweep" } ],
                  first_seen_sprint: ($g.sprints | sort_by(sprintnum) | first),
                  last_confirmed_sprint: ($g.sprints | sort_by(sprintnum) | last),
                  closed_evidence: (if $st == "closed"
                                    then "seeded by migration 008 from a done PBI"
                                    else null end) } ],
      skipped: [ .[] | select((.sprints | length) == 0) | .identity ] }
' "$BACKLOG")"

SKIPPED_N="$(jq -r '.skipped | length' <<<"$CLASS_GROUPS")"
if [ "$SKIPPED_N" -gt 0 ]; then
  printf '[008-seed-audit-ledger] WARNING: %d class(es) have no derivable sprint (unparseable title and no .scrum/sprint.json): %s — transcribe them with update-audit-ledger.sh upsert-class\n' \
    "$SKIPPED_N" "$(jq -r '.skipped | join(", ")' <<<"$CLASS_GROUPS")" >&2
fi

# Classes to add (absent from the ledger) and links to merge (class already
# present, PBI not yet listed). An existing class's status / occurrences /
# detector / severity are never touched — a re-run must not undo wrapper work.
SEED="$(jq -c '.seed' <<<"$CLASS_GROUPS")"
if [ -f "$LEDGER" ]; then
  NEW_N="$(jq -r --argjson seed "$SEED" '
    (.classes // []) as $orig
    | [ $seed[] | select(. as $c | ($orig | any(.identity == $c.identity)) | not) ] | length' "$LEDGER")"
  NEW_LINKS="$(jq -r --argjson seed "$SEED" '
    [ .classes[]? as $x
      | $seed[] | select(.identity == $x.identity)
      | .pbi_ids[] | select(.id as $i | (($x.pbi_ids // []) | any(.id == $i)) | not) ] | length' "$LEDGER")"
else
  NEW_N="$(jq -r 'length' <<<"$SEED")"
  NEW_LINKS=0
fi

if [ -f "$LEDGER" ] && [ "$NEW_N" -eq 0 ] && [ "$NEW_LINKS" -eq 0 ]; then
  printf '[008-seed-audit-ledger] no-op: every audit class is already in %s\n' "$LEDGER"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  if [ -f "$LEDGER" ]; then
    printf '[008-seed-audit-ledger] would add %d class(es) and %d PBI link(s) to %s (dry-run; no file written)\n' \
      "$NEW_N" "$NEW_LINKS" "$LEDGER"
  else
    printf '[008-seed-audit-ledger] would create %s and seed %d class(es) (dry-run; no file written)\n' \
      "$LEDGER" "$NEW_N"
  fi
  exit 0
fi

# Shared source/deployed-layout probe (lib/atomic.sh). Resolved only on the
# write path so the no-op branches above stay schema-independent.
SCHEMA="$(resolve_schema_dir)/audit-ledger.schema.json"

mkdir -p "$(dirname "$LEDGER")"
CREATED=0
if [ ! -f "$LEDGER" ]; then
  NOW="$(_iso_utc_now)"
  # shellcheck disable=SC2016  # $now is a jq -n binding, not a shell variable
  atomic_create "$LEDGER" "$SCHEMA" '{classes: [], updated_at: $now}' --arg now "$NOW"
  CREATED=1
fi

# Add missing classes, then merge missing PBI links into the ones already
# there. Both halves are position-preserving and neither writes `status`,
# `occurrences`, `detector`, or `severity` on a class that already exists.
# The seed array is inlined because atomic_write binds only $now.
EXPR="
  $SEED as \$seed
  | (.classes // []) as \$orig
  | .classes = (
      (\$orig | map(
         . as \$x
         | (\$seed | map(select(.identity == \$x.identity)) | first) as \$s
         | if \$s == null then \$x
           else \$x | .pbi_ids = ((\$x.pbi_ids // [])
                  + [ \$s.pbi_ids[]
                      | select(.id as \$i | ((\$x.pbi_ids // []) | any(.id == \$i)) | not) ])
           end))
      + (\$seed | map(select(. as \$c | (\$orig | any(.identity == \$c.identity)) | not))))"

atomic_write "$LEDGER" "$EXPR" "$SCHEMA"

TOTAL="$(jq -r '.classes | length' "$LEDGER")"
if [ "$CREATED" = 1 ]; then
  printf '[008-seed-audit-ledger] created %s and seeded %d class(es) from existing audit PBIs (%d total)\n' \
    "$LEDGER" "$NEW_N" "$TOTAL"
else
  printf '[008-seed-audit-ledger] added %d class(es) and %d PBI link(s) to %s (%d total)\n' \
    "$NEW_N" "$NEW_LINKS" "$LEDGER" "$TOTAL"
fi
