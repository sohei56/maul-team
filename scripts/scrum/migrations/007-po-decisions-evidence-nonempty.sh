#!/usr/bin/env bash
# migrations/007-po-decisions-evidence-nonempty.sh — drop blank (empty or
# whitespace-only) `evidence` entries from `.scrum/po/decisions.json` so the
# store still satisfies `po-decisions.schema.json` after that array's items
# gained `"pattern": "\\S"`. Idempotent: a second run is a no-op.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated writes,
# missing files are a clean no-op).
#
# Why: `append-po-decision.sh` writes through `atomic_write`, which validates
# the WHOLE file against the schema before the mv. A single pre-existing blank
# evidence string therefore does not merely fail the launch gate — it bricks
# every future append, and `pre-tool-use-scrum-state-guard.sh` blocks agents
# from repairing the JSON by hand. The wrapper only started rejecting a blank
# `--evidence` in the same change that tightened the schema, so records
# carrying `""` are a real legacy shape, not a hypothetical one.
#
# Repair rule: a blank path carries no information, so removing it loses
# nothing. Every record is cleaned, including the approval kinds
# (demo_acceptance / sprint_acceptance / uat_item / release_decision) whose
# `append-po-decision.sh` guard (b) demands at least one path — the schema
# carries no minItems, so an emptied array is valid, and the migration's job is
# to make the launch gate pass rather than to re-adjudicate an approval that
# was already recorded without usable evidence. Each such record is named in a
# stderr WARNING so a human can attach the evidence through the wrapper. Order
# and every other field are preserved byte-for-byte.
#
# One shape is HELD, leaving the file byte-identical: an `evidence` entry that
# is not a string at all. That is pre-existing malformation the schema already
# rejected before this tightening, not something the tightening introduced, and
# deleting data a machine cannot interpret is the failure 005/006 are written
# to avoid. The hold covers the whole file rather than that one record because
# `atomic_write` re-validates the result, so a partial clean could not be
# written without bypassing the schema-validated-write contract. Reported by id
# and exit 0 — a migration must not abort the launch on a judgement call; the
# validation phase reports the file, and a human edit plus a relaunch cleans
# the rest.
#
# Usage: scripts/scrum/migrations/007-po-decisions-evidence-nonempty.sh [--dry-run]
# Runs in the cwd against .scrum/po/decisions.json. Prints a one-line summary.
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

PATHF=".scrum/po/decisions.json"

if [ ! -f "$PATHF" ]; then
  echo "[007-po-decisions-evidence-nonempty] skip: $PATHF not present"
  exit 0
fi

# Kinds whose evidence array is meant to stay non-empty. Mirrors guard (b) in
# append-po-decision.sh; the schema states the rule only in prose (there is no
# minItems / conditional), so there is nothing machine-readable to derive it
# from. Used for the warning only — never to skip a record.
REQUIRED_KINDS='["demo_acceptance","sprint_acceptance","uat_item","release_decision"]'

# One pass over the store. Per decision: how many evidence entries survive the
# blank filter and how many are not strings at all. `blanks` / `touched`
# describe the work; `nonstring` holds the file; `emptied` names the approval
# records that come out with an empty array.
# shellcheck disable=SC2016  # $req/$d/$rows are jq bindings, not shell variables
STATS="$(jq -c --argjson req "$REQUIRED_KINDS" '
  [ .decisions[]?
    | select((.evidence // null) != null)
    | . as $d
    | { id: ($d.id // "<no id>"),
        kind: ($d.kind // "<no kind>"),
        n_before: ($d.evidence | length),
        n_kept: ([ $d.evidence[]
                   | select(if type == "string" then test("\\S") else true end)
                 ] | length),
        n_nonstring: ([ $d.evidence[] | select(type != "string") ] | length),
        required: (($req | index($d.kind)) != null) }
  ] as $rows
  | { blanks:    ([ $rows[] | (.n_before - .n_kept) ] | add // 0),
      touched:   ([ $rows[] | select(.n_before > .n_kept) ] | length),
      nonstring: [ $rows[] | select(.n_nonstring > 0) | .id ],
      emptied:   [ $rows[]
                   | select(.required and .n_before > 0 and .n_kept == 0)
                   | "\(.id) (kind=\(.kind))" ] }
' "$PATHF")"

BLANKS="$(jq -r '.blanks' <<<"$STATS")"
TOUCHED="$(jq -r '.touched' <<<"$STATS")"
NONSTRING_N="$(jq -r '.nonstring | length' <<<"$STATS")"
EMPTIED_N="$(jq -r '.emptied | length' <<<"$STATS")"

if [ "$NONSTRING_N" -gt 0 ]; then
  printf '[007-po-decisions-evidence-nonempty] WARNING: %d decisions carry a non-string evidence entry: %s\n' \
    "$NONSTRING_N" "$(jq -r '.nonstring | join(", ")' <<<"$STATS")" >&2
  printf '[007-po-decisions-evidence-nonempty] held: %s left byte-identical — a non-string entry predates this tightening and cannot be interpreted automatically; hand-edit the named records, then relaunch to clean the rest\n' \
    "$PATHF"
  exit 0
fi

if [ "$BLANKS" -eq 0 ]; then
  printf '[007-po-decisions-evidence-nonempty] no-op: no blank evidence entries\n'
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '[007-po-decisions-evidence-nonempty] would drop %d blank evidence entries across %d decisions (%d approval records would be left with no evidence) (dry-run; no file written)\n' \
    "$BLANKS" "$TOUCHED" "$EMPTIED_N"
  exit 0
fi

# One line per approval record that comes out empty, so the id is greppable.
if [ "$EMPTIED_N" -gt 0 ]; then
  jq -r '.emptied[]' <<<"$STATS" | while IFS= read -r rec; do
    printf '[007-po-decisions-evidence-nonempty] WARNING: %s — evidence was blank; record kept, please attach evidence via .scrum/scripts/append-po-decision.sh\n' \
      "$rec" >&2
  done
fi

# The blank filter is inlined rather than passed as a jq --arg because
# atomic_write binds only $now — it takes no extra jq arguments. The
# non-string guard inside `select` is unreachable here (that case exits above)
# and kept only so the expression is correct read on its own.
EXPR='
  .decisions |= map(
    if (.evidence // null) == null
    then .
    else
      .evidence = [ .evidence[]
                    | select(if type == "string" then test("\\S") else true end) ]
    end
  )
'

# Shared source/deployed-layout probe (lib/atomic.sh). Resolved only on the
# write path so the no-op branches above stay schema-independent.
SCHEMA="$(resolve_schema_dir)/po-decisions.schema.json"

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

printf '[007-po-decisions-evidence-nonempty] dropped %d blank evidence entries across %d decisions (%d approval records left with no evidence — see warnings)\n' \
  "$BLANKS" "$TOUCHED" "$EMPTIED_N"
