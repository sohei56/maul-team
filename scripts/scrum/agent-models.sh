#!/usr/bin/env bash
# scripts/scrum/agent-models.sh — the sole writer of .scrum/config.json
# `.agents`, the per-seat LLM provider/model table (SSOT for model selection).
#
# Usage:
#   agent-models.sh set <seat> [<provider>:]<model>[@<effort>]
#       Upsert one seat. Provider omitted → the seat's catalog default
#       provider. Effort omitted → the seat's previously configured effort
#       (same provider) is kept; otherwise the catalog default applies at
#       resolve time. On a codex seat `default` (or JSON null via set-table)
#       means "no -m flag" and is stored as null.
#   agent-models.sh set-table '<json>'
#       Replace the whole .agents block in ONE validated write. <json> is an
#       object keyed by seat; each value is {provider, model, effort?}.
#   agent-models.sh resolve
#       Read-only. Print the full seat table (catalog defaults overlaid by
#       .agents, keys in catalog order) as JSON on stdout. Missing config
#       file / missing block are fine. Machine-readable: harness input.
#   agent-models.sh materialize [--agents-dir <dir>]   (default .claude/agents)
#       For every seat whose provider has materialize_frontmatter:true, patch
#       the `model:` (and `effort:` when set) line of each listed agent file.
#       Never inserts a missing key; never touches unlisted files; silently
#       skips files that are not deployed. Prints one line per seat.
#   agent-models.sh --help
#
# Validation (exit 64 = E_INVALID_ARG): seat ∈ catalog seats; provider ∈
# seats.<seat>.providers; effort only for providers that declare `efforts`
# and ∈ that list; model token ∈ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ (claude) /
# ^[A-Za-z0-9][A-Za-z0-9._-]*$ (codex). A model id absent from the catalog
# menu is accepted with a one-line WARN on stderr (the menu is advisory —
# model ids churn). A write whose result violates config.schema.json exits
# 65 (E_SCHEMA); a missing catalog or schema exits 67 (E_FILE_MISSING).
#
# Catalog: docs/contracts/model-catalog.json (seat membership, defaults,
# menus), located next to the scrum-state schema dir. Direct edits to
# .scrum/config.json are blocked by the scrum-state PreToolUse guard.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/frontmatter.sh
source "$HERE/lib/frontmatter.sh"

usage() {
  cat <<'EOF'
usage: agent-models.sh <subcommand> [args]
  set <seat> [<provider>:]<model>[@<effort>]   upsert one seat
  set-table '<json>'                           replace the whole .agents block
  resolve                                      print resolved 9-seat table (JSON)
  materialize [--agents-dir <dir>]             patch model:/effort: in agent files
  --help                                       this text
Seats / providers / efforts: docs/contracts/model-catalog.json.
EOF
}

PATHF=".scrum/config.json"
CLAUDE_TOKEN_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
CODEX_TOKEN_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

[ "$#" -ge 1 ] || { usage >&2; fail E_INVALID_ARG "missing subcommand"; }
case "$1" in
  --help|-h|help) usage; exit 0 ;;
esac

SCHEMA_DIR="$(resolve_schema_dir)"
SCHEMA="$SCHEMA_DIR/config.schema.json"
CATALOG="$(dirname "$SCHEMA_DIR")/model-catalog.json"
[ -f "$CATALOG" ] || fail E_FILE_MISSING "$CATALOG"

# --- catalog queries --------------------------------------------------------

catalog_seats_in_order() {
  jq -r '.seats | to_entries | sort_by(.value.order) | .[].key' "$CATALOG"
}

seat_exists() {
  jq -e --arg s "$1" '.seats[$s] != null' "$CATALOG" >/dev/null
}

seat_default_provider() {
  jq -r --arg s "$1" '.seats[$s].default.provider' "$CATALOG"
}

seat_allows_provider() {
  jq -e --arg s "$1" --arg p "$2" '.seats[$s].providers | index($p) != null' "$CATALOG" >/dev/null
}

provider_has_efforts() {
  jq -e --arg p "$1" '(.providers[$p].efforts // []) | length > 0' "$CATALOG" >/dev/null
}

provider_allows_effort() {
  jq -e --arg p "$1" --arg e "$2" '(.providers[$p].efforts // []) | index($e) != null' "$CATALOG" >/dev/null
}

provider_knows_model() {
  jq -e --arg p "$1" --arg m "$2" '.providers[$p].models | any(.id == $m)' "$CATALOG" >/dev/null
}

# Current .agents block as compact JSON ({} when file/block absent; non-object
# values are treated as absent so a corrupt block cannot poison a resolve).
current_agents_json() {
  if [ -f "$PATHF" ]; then
    jq -c '.agents | if type == "object" then . else {} end' "$PATHF" \
      || fail E_INVALID_ARG "$PATHF is not valid JSON"
  else
    printf '{}\n'
  fi
}

# --- per-seat validation ----------------------------------------------------

# validate_seat_entry <seat> <provider> <model> <effort>
# Emits the validated entry as compact JSON on stdout. <model> "default" on
# a provider without materialize_frontmatter (codex) becomes null.
validate_seat_entry() {
  local seat="$1" provider="$2" model="$3" effort="$4" model_json
  seat_exists "$seat" || fail E_INVALID_ARG \
    "unknown seat: $seat (known: $(catalog_seats_in_order | tr '\n' ' ' | sed 's/ $//'))"
  [ -n "$provider" ] || fail E_INVALID_ARG "$seat: provider must be non-empty"
  jq -e --arg p "$provider" '.providers[$p] != null' "$CATALOG" >/dev/null \
    || fail E_INVALID_ARG "$seat: unknown provider: $provider"
  seat_allows_provider "$seat" "$provider" || fail E_INVALID_ARG \
    "$seat: provider $provider not allowed (allowed: $(jq -r --arg s "$seat" '.seats[$s].providers | join(" ")' "$CATALOG"))"
  [ -n "$model" ] || fail E_INVALID_ARG "$seat: model must be non-empty"

  if [ "$provider" = "codex" ] && [ "$model" = "default" ]; then
    model_json="null"
  else
    case "$provider" in
      codex) [[ "$model" =~ $CODEX_TOKEN_RE ]] ;;
      *)     [[ "$model" =~ $CLAUDE_TOKEN_RE ]] ;;
    esac || fail E_INVALID_ARG \
      "$seat: unsafe model token: $model (letters, digits, '.', '_', '-'$([ "$provider" = codex ] || printf ", '/'") only; single line)"
    if ! provider_knows_model "$provider" "$model"; then
      printf '[agent-models] WARN: %s: model %s is not in the %s catalog menu (accepted; the menu is advisory)\n' \
        "$seat" "$model" "$provider" >&2
    fi
    model_json="$(jq -n --arg m "$model" '$m')"
  fi

  if [ -n "$effort" ]; then
    provider_has_efforts "$provider" || fail E_INVALID_ARG \
      "$seat: provider $provider has no effort setting (drop @<effort>)"
    provider_allows_effort "$provider" "$effort" || fail E_INVALID_ARG \
      "$seat: unknown effort: $effort (allowed: $(jq -r --arg p "$provider" '.providers[$p].efforts | join(" ")' "$CATALOG"))"
    jq -cn --arg p "$provider" --argjson m "$model_json" --arg e "$effort" \
      '{provider: $p, model: $m, effort: $e}'
  else
    jq -cn --arg p "$provider" --argjson m "$model_json" '{provider: $p, model: $m}'
  fi
}

# parse_spec <seat> <spec> — sets SPEC_PROVIDER / SPEC_MODEL / SPEC_EFFORT from
# `[<provider>:]<model>[@<effort>]`. ':' and '@' are outside the model token
# alphabet, so the split is unambiguous.
parse_spec() {
  local seat="$1" spec="$2" rest
  case "$spec" in
    *:*) SPEC_PROVIDER="${spec%%:*}"; rest="${spec#*:}" ;;
    *)   SPEC_PROVIDER="$(seat_default_provider "$seat")"; rest="$spec" ;;
  esac
  case "$rest" in
    *@*) SPEC_MODEL="${rest%%@*}"; SPEC_EFFORT="${rest#*@}"
         [ -n "$SPEC_EFFORT" ] || fail E_INVALID_ARG "$seat: effort after '@' must be non-empty" ;;
    *)   SPEC_MODEL="$rest"; SPEC_EFFORT="" ;;
  esac
}

# write_agents_table <compact-json>
# Single validated write of the whole .agents block (creates the file if absent).
write_agents_table() {
  local table="$1"
  if [ -f "$PATHF" ]; then
    atomic_write "$PATHF" ".agents = $table" "$SCHEMA"
  else
    mkdir -p .scrum
    atomic_create "$PATHF" "$SCHEMA" "{agents: $table}"
  fi
}

describe_entry() {
  # describe_entry <seat> <entry-json> → "<provider> <model> (effort <e|->)"
  jq -r '"\(.provider) \(.model // "default") (effort \(.effort // "-"))"' <<<"$2"
}

# --- subcommands ------------------------------------------------------------

cmd_set() {
  [ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: agent-models.sh set <seat> [<provider>:]<model>[@<effort>]"
  local seat="$1" spec="$2" entry current prior_effort table
  seat_exists "$seat" || fail E_INVALID_ARG \
    "unknown seat: $seat (known: $(catalog_seats_in_order | tr '\n' ' ' | sed 's/ $//'))"
  parse_spec "$seat" "$spec"
  current="$(current_agents_json)"
  if [ -z "$SPEC_EFFORT" ]; then
    # Keep a previously configured effort when the provider is unchanged.
    prior_effort="$(jq -r --arg s "$seat" --arg p "$SPEC_PROVIDER" \
      '.[$s] | select(type == "object" and .provider == $p) | .effort // empty' <<<"$current")"
    SPEC_EFFORT="$prior_effort"
  fi
  entry="$(validate_seat_entry "$seat" "$SPEC_PROVIDER" "$SPEC_MODEL" "$SPEC_EFFORT")"
  table="$(jq -c --arg s "$seat" --argjson e "$entry" '. + {($s): $e}' <<<"$current")"
  write_agents_table "$table"
  printf '[agent-models] %s: %s\n' "$seat" "$(describe_entry "$seat" "$entry")"
}

cmd_set_table() {
  [ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: agent-models.sh set-table '<json>'"
  local input seat entry provider model effort table unknown
  input="$(jq -c '.' <<<"$1" 2>/dev/null)" || fail E_INVALID_ARG "set-table: not valid JSON"
  jq -e 'type == "object"' <<<"$input" >/dev/null \
    || fail E_INVALID_ARG "set-table: expected an object keyed by seat"
  # A seat the catalog no longer defines (renamed/dropped in a later release)
  # is dropped with a WARN rather than rejected: rejecting would make every
  # later write — and every launch — fail with no sanctioned way to prune it.
  unknown="$(jq -r --slurpfile c "$CATALOG" '[keys[] | select(($c[0].seats[.]) == null)] | join(" ")' <<<"$input")"
  [ -z "$unknown" ] || printf '[agent-models] WARN: set-table: dropping seat(s) not in the catalog: %s\n' "$unknown" >&2

  # Read the seat list up front: a command substitution inside the heredoc
  # below cannot fail the script, and an unreadable catalog would otherwise
  # silently write an empty table.
  local seats
  seats="$(catalog_seats_in_order)" || fail E_FILE_MISSING "unreadable catalog: $CATALOG"
  [ -n "$seats" ] || fail E_FILE_MISSING "catalog defines no seats: $CATALOG"

  table="{}"
  while IFS= read -r seat; do
    jq -e --arg s "$seat" 'has($s)' <<<"$input" >/dev/null || continue
    jq -e --arg s "$seat" '.[$s] | type == "object"' <<<"$input" >/dev/null \
      || fail E_INVALID_ARG "set-table: $seat: value must be an object {provider, model, effort?}"
    unknown="$(jq -r --arg s "$seat" '.[$s] | [keys[] | select(. != "provider" and . != "model" and . != "effort")] | join(" ")' <<<"$input")"
    [ -z "$unknown" ] || fail E_INVALID_ARG "set-table: $seat: unknown key(s): $unknown"
    jq -e --arg s "$seat" '.[$s] | (.provider | type) == "string"' <<<"$input" >/dev/null \
      || fail E_INVALID_ARG "set-table: $seat: provider must be a string"
    jq -e --arg s "$seat" '.[$s] | (.model | type) == "string" or (.model == null)' <<<"$input" >/dev/null \
      || fail E_INVALID_ARG "set-table: $seat: model must be a string (or null on a codex seat)"
    jq -e --arg s "$seat" '.[$s] | (has("effort") | not) or (.effort | type) == "string"' <<<"$input" >/dev/null \
      || fail E_INVALID_ARG "set-table: $seat: effort must be a string"
    provider="$(jq -r --arg s "$seat" '.[$s].provider' <<<"$input")"
    model="$(jq -r --arg s "$seat" '.[$s].model // "default"' <<<"$input")"
    effort="$(jq -r --arg s "$seat" '.[$s].effort // ""' <<<"$input")"
    if [ "$model" = "default" ] && [ "$provider" != "codex" ]; then
      # jq `//` folded an explicit null into "default"; only codex may be null.
      jq -e --arg s "$seat" '.[$s].model == null' <<<"$input" >/dev/null \
        && fail E_INVALID_ARG "set-table: $seat: model null is only valid on a codex seat"
    fi
    entry="$(validate_seat_entry "$seat" "$provider" "$model" "$effort")"
    table="$(jq -c --arg s "$seat" --argjson e "$entry" '. + {($s): $e}' <<<"$table")"
  done <<EOF
$seats
EOF

  write_agents_table "$table"
  printf '[agent-models] agents table replaced (%s seat(s))\n' "$(jq 'length' <<<"$table")"
}

resolve_table() {
  jq -n --slurpfile cat "$CATALOG" --argjson cfg "$(current_agents_json)" '
    $cat[0] as $c
    | reduce ($c.seats | to_entries | sort_by(.value.order) | .[]) as $s ({};
        ($s.value.default) as $d
        | ($cfg[$s.key] | if type == "object" then . else {} end) as $o
        | (($d + $o) | .provider) as $p
        | . + {($s.key): (($d + $o)
                          | if (($c.providers[$p].efforts // []) | length) == 0 then del(.effort) else . end)})
  '
}

cmd_resolve() {
  [ "$#" -eq 0 ] || fail E_INVALID_ARG "usage: agent-models.sh resolve"
  resolve_table
}

cmd_materialize() {
  local agents_dir=".claude/agents" resolved seat entry provider model effort agent file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agents-dir) [ "$#" -ge 2 ] || fail E_INVALID_ARG "--agents-dir requires a value"
                    agents_dir="$2"; shift 2 ;;
      *) fail E_INVALID_ARG "materialize: unknown argument: $1" ;;
    esac
  done
  local seats missing
  seats="$(catalog_seats_in_order)" || fail E_FILE_MISSING "unreadable catalog: $CATALOG"
  resolved="$(resolve_table)"
  while IFS= read -r seat; do
    entry="$(jq -c --arg s "$seat" '.[$s]' <<<"$resolved")"
    provider="$(jq -r '.provider' <<<"$entry")"
    model="$(jq -r '.model // "default"' <<<"$entry")"
    effort="$(jq -r '.effort // ""' <<<"$entry")"
    if jq -e --arg p "$provider" '.providers[$p].materialize_frontmatter == true' "$CATALOG" >/dev/null; then
      # Files whose frontmatter has no `effort:` key keep running at Claude
      # Code's default effort (the helper never inserts); say so instead of
      # reporting an effort that was not applied.
      missing=""
      while IFS= read -r agent; do
        file="$agents_dir/$agent.md"
        [ -f "$file" ] || continue
        patch_frontmatter_key "$file" model "$model" || true
        if [ -n "$effort" ]; then
          patch_frontmatter_key "$file" effort "$effort" || missing="${missing:+$missing, }$agent.md"
        fi
      done <<EOF
$(jq -r --arg s "$seat" '.seats[$s].agents[]' "$CATALOG")
EOF
      if [ -n "$missing" ]; then
        printf '  %s: %s — effort NOT applied (no effort: key in %s)\n' \
          "$seat" "$(describe_entry "$seat" "$entry")" "$missing"
      else
        printf '  %s: %s\n' "$seat" "$(describe_entry "$seat" "$entry")"
      fi
    else
      # Non-materialized provider: the model is passed on the CLI at spawn
      # time (codex-invoke.sh `codex exec -m`); null shows as `default`.
      printf '  %s: %s %s (Codex CLI -m)\n' "$seat" "$provider" "$model"
    fi
  done <<EOF
$seats
EOF
}

SUB="$1"; shift
case "$SUB" in
  set)         cmd_set "$@" ;;
  set-table)   cmd_set_table "$@" ;;
  resolve)     cmd_resolve "$@" ;;
  materialize) cmd_materialize "$@" ;;
  *) usage >&2; fail E_INVALID_ARG "unknown subcommand: $SUB" ;;
esac
