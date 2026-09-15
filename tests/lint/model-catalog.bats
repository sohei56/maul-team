#!/usr/bin/env bats
# tests/lint/model-catalog.bats — pin docs/contracts/model-catalog.json to the
# source agents/*.md frontmatter. The catalog is the SSOT for seat membership
# and per-seat defaults; the frontmatter `model:`/`effort:` lines are a
# materialized view of it (written by agent-models.sh in deployed targets).
# Drift between the two would make a fresh deploy silently change models, so
# every seat default must equal the source frontmatter, every model-bearing
# agent must belong to exactly one seat, and excluded agents must carry no
# `model:` at all.

load '../test_helper/common-setup'

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CATALOG="$PROJECT_ROOT/docs/contracts/model-catalog.json"
  AGENTS_DIR="$PROJECT_ROOT/agents"
}

# Extract YAML frontmatter (lines between the two --- markers). Same awk idiom
# as tests/lint/agent-frontmatter.bats (BSD sed lacks the range syntax).
_frontmatter() {
  awk 'NR==1 && !/^---$/{exit} NR==1{next} /^---$/{exit} {print}' "$1"
}

# Frontmatter scalar as a string; "null" when absent.
_fm_field() {
  _frontmatter "$1" | yq -r ".$2"
}

# --- (a) catalog parses -----------------------------------------------------

@test "model-catalog: parses and carries providers, seats, excluded_agents" {
  run jq -e '
    (.schema_version | type == "number") and
    (.providers | type == "object") and
    (.seats | type == "object") and
    (.excluded_agents | type == "array")
  ' "$CATALOG"
  assert_success
}

# --- (b) every model-bearing agent belongs to exactly one seat --------------

@test "model-catalog: every agents/*.md with model: belongs to exactly one seat" {
  local f name count
  for f in "$AGENTS_DIR"/*.md; do
    name="$(basename "$f" .md)"
    [ "$(_fm_field "$f" model)" != "null" ] || continue
    count="$(jq -r --arg a "$name" \
      '[.seats[].agents[] | select(. == $a)] | length' "$CATALOG")"
    [ "$count" -eq 1 ] || {
      echo "$name has model: in frontmatter but appears in $count seat(s) (expected 1)" >&2
      return 1
    }
  done
}

# --- (c) seat defaults == source frontmatter --------------------------------

@test "model-catalog: seat default model/effort equal source frontmatter for materialized providers" {
  local seat provider materialize agent f exp_model exp_effort got_model got_effort
  for seat in $(jq -r '.seats | keys[]' "$CATALOG"); do
    provider="$(jq -r --arg s "$seat" '.seats[$s].default.provider' "$CATALOG")"
    materialize="$(jq -r --arg p "$provider" '.providers[$p].materialize_frontmatter' "$CATALOG")"
    exp_model="$(jq -r --arg s "$seat" '.seats[$s].default.model' "$CATALOG")"
    exp_effort="$(jq -r --arg s "$seat" '.seats[$s].default.effort' "$CATALOG")"
    for agent in $(jq -r --arg s "$seat" '.seats[$s].agents[]' "$CATALOG"); do
      f="$AGENTS_DIR/$agent.md"
      [ -f "$f" ] || { echo "seat $seat lists missing agent file $f" >&2; return 1; }
      # Codex seats: frontmatter is not a view of the catalog (the file's
      # model: governs the Claude wrapper process, not the Codex CLI).
      [ "$materialize" = "true" ] || continue
      got_model="$(_fm_field "$f" model)"
      got_effort="$(_fm_field "$f" effort)"
      [ "$got_model" = "$exp_model" ] || {
        echo "$agent: frontmatter model=$got_model but seat $seat default=$exp_model" >&2
        return 1
      }
      [ "$got_effort" = "$exp_effort" ] || {
        echo "$agent: frontmatter effort=$got_effort but seat $seat default=$exp_effort" >&2
        return 1
      }
    done
  done
}

# --- (d) excluded agents exist and carry no model: --------------------------

@test "model-catalog: every excluded agent exists and has no model: in frontmatter" {
  local agent f
  for agent in $(jq -r '.excluded_agents[]' "$CATALOG"); do
    f="$AGENTS_DIR/$agent.md"
    [ -f "$f" ] || { echo "excluded agent file missing: $f" >&2; return 1; }
    [ "$(_fm_field "$f" model)" = "null" ] || {
      echo "$agent is excluded but carries model: in frontmatter" >&2
      return 1
    }
  done
}

# --- (e) default.provider is a known provider and accepted by the seat ------

@test "model-catalog: every seat default.provider is declared and in the seat's providers[]" {
  run jq -e '
    .providers as $p |
    [.seats | to_entries[] |
      .value.default.provider as $d |
      select(
        ($p | has($d) | not) or
        ((.value.providers | index($d)) == null)
      ) | .key] == []
  ' "$CATALOG"
  assert_success
}

# --- (f) order unique, group in {team, pipeline} ----------------------------

@test "model-catalog: seat order values are unique integers" {
  run jq -e '
    [.seats[].order] as $o |
    ($o | all(type == "number")) and
    (($o | unique | length) == ($o | length))
  ' "$CATALOG"
  assert_success
}

@test "model-catalog: every seat group is team or pipeline" {
  run jq -e '[.seats[].group] | all(. == "team" or . == "pipeline")' "$CATALOG"
  assert_success
}

# --- (g) codex is non-materialized; phase_b_providers ⊇ providers -----------

@test "model-catalog: codex provider does not materialize frontmatter" {
  run jq -e '.providers.codex.materialize_frontmatter == false' "$CATALOG"
  assert_success
}

@test "model-catalog: every seat phase_b_providers is a superset of providers" {
  run jq -e '
    [.seats | to_entries[] |
      select((.value.providers - .value.phase_b_providers) != []) | .key] == []
  ' "$CATALOG"
  assert_success
}
