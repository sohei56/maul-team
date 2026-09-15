#!/usr/bin/env bash
# migrations/009-seed-agent-models.sh — seed the per-seat LLM table
# `.scrum/config.json.agents` for projects launched before the table existed.
# Runs under scripts/scrum/migrate-state.sh (see its header for the migration
# contract: cwd = target root, idempotent, --dry-run, schema-validated writes,
# missing files are a clean no-op).
#
# Why a migration and not just the launcher: before the table, a `--sm-model`
# / `--po-model` choice was persisted ONLY as the `model:` line of the
# deployed `.claude/agents/<name>.md` (scrum-start.sh re-captured it from
# there on every launch). Once `.agents` is the SSOT the launcher seeds from
# the catalog default and would silently drop that earlier choice. This
# migration runs first and imports it, once, from the deployed frontmatter.
#
# Seeding rules, and what is deliberately NOT invented:
#   - Seat membership, ordering, and per-seat defaults come from
#     docs/contracts/model-catalog.json, never from this script.
#   - A claude seat (catalog `providers.<p>.materialize_frontmatter` true)
#     imports `model:` / `effort:` from `.claude/agents/<agents[0]>.md` when
#     that file exists. A model that fails the schema's token alphabet, or an
#     effort outside the provider's `efforts` list, is reported and the
#     catalog default is kept — a malformed deployed file must never brick
#     the launch through a failed schema validation.
#   - A codex seat is always `{provider: "codex", model: null}` (the CLI
#     default). Nothing in a deployed agent file describes a Codex model.
#   - `.agents` already present → no-op, byte-identical. The launcher owns
#     the table from then on; this migration never re-derives it.
#   - No `.claude/agents/` → skip. There is nothing to import; the launcher
#     seeds the table from the catalog.
#   - Catalog not deployed → WARN and exit 0 (an older deployment that copied
#     only the schemas); the launcher's own seeding still runs.
#
# Usage: scripts/scrum/migrations/009-seed-agent-models.sh [--dry-run]
# Runs in the cwd against .scrum/config.json. Prints a one-line summary.
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
# shellcheck source=../lib/frontmatter.sh
source "$HERE/../lib/frontmatter.sh"

TAG="[009-seed-agent-models]"
CONFIG=".scrum/config.json"
AGENTS_DIR=".claude/agents"

if [ -f "$CONFIG" ] && jq -e 'has("agents")' "$CONFIG" >/dev/null 2>&1; then
  echo "$TAG no-op: $CONFIG already carries .agents"
  exit 0
fi

if [ ! -d "$AGENTS_DIR" ]; then
  echo "$TAG skip: $AGENTS_DIR not present (nothing to import; the launcher seeds the table)"
  exit 0
fi

# Shared source/deployed-layout probe (lib/atomic.sh). The catalog is
# deployed beside the schema directory (docs/contracts/model-catalog.json).
SCHEMA_DIR="$(resolve_schema_dir)"
CATALOG="$(dirname "$SCHEMA_DIR")/model-catalog.json"
if [ ! -f "$CATALOG" ]; then
  echo "$TAG WARNING: model catalog not found at $CATALOG — skipping legacy import (the launcher seeds the table)" >&2
  exit 0
fi

# Same alphabet as config.schema.json definitions.claude_seat.model and
# scrum-start.sh::is_safe_model_token.
_is_safe_model_token() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

# Build the table one seat at a time, catalog order. Bash 3.2: no associative
# arrays, so the object is accumulated in a jq string via --argjson.
SEATS="$(jq -r '.seats | to_entries | sort_by(.value.order) | .[].key' "$CATALOG")"
AGENTS='{}'
N_SEATS=0
N_IMPORTED=0
for seat in $SEATS; do
  N_SEATS=$((N_SEATS + 1))
  DEFAULT="$(jq -c --arg s "$seat" '.seats[$s].default' "$CATALOG")"
  PROVIDER="$(jq -r '.provider' <<<"$DEFAULT")"
  ENTRY="$DEFAULT"
  if [ "$PROVIDER" = "codex" ]; then
    ENTRY='{"provider":"codex","model":null}'
  else
    MATERIALIZE="$(jq -r --arg p "$PROVIDER" '.providers[$p].materialize_frontmatter // false' "$CATALOG")"
    AGENT="$(jq -r --arg s "$seat" '.seats[$s].agents[0] // ""' "$CATALOG")"
    FILE="$AGENTS_DIR/$AGENT.md"
    if [ "$MATERIALIZE" = "true" ] && [ -n "$AGENT" ] && [ -f "$FILE" ]; then
      # lib/frontmatter.sh: first key inside the leading `---` block only,
      # whitespace and one quote pair stripped (`model: "fable"` == fable).
      MODEL="$(capture_frontmatter_key "$FILE" model || true)"
      EFFORT="$(capture_frontmatter_key "$FILE" effort || true)"
      if [ -n "$MODEL" ]; then
        if _is_safe_model_token "$MODEL"; then
          ENTRY="$(jq -c --arg m "$MODEL" '.model = $m' <<<"$ENTRY")"
        else
          printf '%s WARNING: ignoring syntactically invalid deployed model for seat %s (%s): %s — keeping catalog default %s\n' \
            "$TAG" "$seat" "$FILE" "$MODEL" "$(jq -r '.model' <<<"$DEFAULT")" >&2
        fi
      fi
      if [ -n "$EFFORT" ]; then
        # Accept only an effort the provider lists (schema pattern ^[a-z]+$
        # is implied by that list); an empty/absent list falls back to the
        # pattern alone.
        if jq -e --arg p "$PROVIDER" --arg e "$EFFORT" '
             (.providers[$p].efforts // []) as $ok
             | if ($ok | length) > 0 then ($ok | index($e)) != null
               else ($e | test("^[a-z]+$")) end' "$CATALOG" >/dev/null; then
          ENTRY="$(jq -c --arg e "$EFFORT" '.effort = $e' <<<"$ENTRY")"
        else
          printf '%s WARNING: ignoring unknown deployed effort for seat %s (%s): %s — keeping catalog default %s\n' \
            "$TAG" "$seat" "$FILE" "$EFFORT" "$(jq -r '.effort // "unset"' <<<"$DEFAULT")" >&2
        fi
      fi
    fi
  fi
  if ! jq -e -n --argjson a "$ENTRY" --argjson b "$DEFAULT" '$a == $b' >/dev/null; then
    N_IMPORTED=$((N_IMPORTED + 1))
  fi
  AGENTS="$(jq -c --arg s "$seat" --argjson e "$ENTRY" '.[$s] = $e' <<<"$AGENTS")"
done

if [ "$DRY_RUN" = 1 ]; then
  printf '%s would seed agents for %d seats (%d imported from deployed frontmatter) (dry-run; no file written)\n' \
    "$TAG" "$N_SEATS" "$N_IMPORTED"
  exit 0
fi

SCHEMA="$SCHEMA_DIR/config.schema.json"
if [ -f "$CONFIG" ]; then
  # The table is inlined because atomic_write binds only $now.
  atomic_write "$CONFIG" ".agents = $AGENTS" "$SCHEMA"
else
  mkdir -p "$(dirname "$CONFIG")"
  # shellcheck disable=SC2016  # $agents is a jq -n binding, not a shell variable
  atomic_create "$CONFIG" "$SCHEMA" '{agents: $agents}' --argjson agents "$AGENTS"
fi

printf '%s seeded agents (%d imported from deployed frontmatter)\n' "$TAG" "$N_IMPORTED"
