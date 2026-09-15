#!/usr/bin/env bash
# scrum-start.sh — Entry point for Maul Team (AI-powered Scrum team)
#
# Usage (interactive / human-PO mode):
#   sh scrum-start.sh [--sm-model <name>] [--agent-model <seat>=<spec>]...
#   On a NEW project with no docs/product/brief.md, an interactive Claude
#   session co-authors the product brief (create-brief skill) first; the
#   Scrum Master's Requirement Definition then begins with that brief as its
#   anchor. Exiting without writing a brief aborts the launch.
#
# Usage (autonomous-PO mode — Ralph Loop, no human at the keyboard):
#   sh scrum-start.sh --autonomous [--brief docs/product/brief.md] \
#                     [--max-sprints N] [--max-hours H] \
#                     [--sm-model <name>] [--po-model <name>] \
#                     [--agent-model <seat>=<spec>]... \
#                     [--bypass-permissions] [--no-attach]
#
# Flags:
#   --autonomous            Launch the watchdog (scripts/autonomous/watchdog.sh)
#                           instead of an interactive Claude session. The
#                           watchdog drives the Scrum Master headlessly until
#                           `state.json.phase == complete` or a safety valve
#                           trips.
#   --brief <file>          Required when starting a new project autonomously
#                           (no .scrum/state.json exists). Copied to
#                           docs/product/brief.md as the seed input.
#   --max-sprints N         Overrides `.scrum/config.json.autonomous.max_sprints`.
#   --max-hours H           Overrides `.scrum/config.json.autonomous.max_wall_clock_hours`.
#   --agent-model <seat>=[<provider>:]<model>[@<effort>]
#                           Repeatable. Sets one seat of the per-seat model
#                           table `.scrum/config.json.agents` (the SSOT for
#                           provider + model; seats, defaults and menus in
#                           docs/contracts/model-catalog.json). Examples:
#                             --agent-model codex-reviewers=codex:gpt-5.6-luna
#                             --agent-model developer=claude:opus@high
#                             --agent-model integrity-reviewers=sonnet
#                           Provider omitted = the seat's default provider;
#                           `codex:default` = the Codex CLI default (no -m).
#                           Unknown seat / disallowed provider / bad effort /
#                           unsafe token, or the same seat twice: exit 2.
#   --sm-model <name>       Sets the Scrum Master model in both human-PO and
#                           autonomous-PO modes. Shorthand for
#                           `--agent-model scrum-master=claude:<name>`.
#                           Accepts CLI aliases (`opus`, `fable`, `sonnet`,
#                           `haiku`) or a specific model ID.
#   --po-model <name>       Shorthand for
#                           `--agent-model product-owner=claude:<name>`.
#                           Accepted in both modes and persisted; the
#                           product-owner teammate itself is only spawned in
#                           autonomous mode.
#   --bypass-permissions    Sets autonomous.permission_mode = bypassPermissions
#                           (default: dontAsk).
#   --no-attach             Skip `tmux attach-session` after launching; useful
#                           when starting overnight runs.
#
# Per-seat models: choices persist in `.scrum/config.json.agents` across
#   re-runs (a pre-table project's deployed frontmatter is imported once by
#   migration 009). After setup-user.sh refreshes the deployed agent files,
#   `.scrum/scripts/agent-models.sh materialize` rewrites each Claude seat's
#   `model:` / `effort:` frontmatter from the table; the Codex reviewer model
#   is passed as `codex exec -m` by codex-invoke.sh. Fields:
#   docs/data-model.md § Entity: Config.
#
# Interactive wizard:
#   On a TTY, the Scrum Master model is selected in both PO modes (autonomous
#   mode also asks for the Product Owner model); other seats are set only via
#   --agent-model or the Mac app. Autonomous mode also prompts for any other
#   setting not supplied via CLI. Press Enter to accept the prior/default
#   value (persisted table > catalog default). Prompts are skipped on non-TTY
#   stdin and under SCRUM_START_DRY_RUN=1 — CLI flags and persisted values
#   remain authoritative in those cases.
#
# Prerequisites:
#   - Claude Code CLI on PATH (>= 2.1.172 recommended; older versions
#     emit a warning — sub-agents-spawning-sub-agents is required for
#     the PBI pipeline and was unlocked upstream in 2.1.172)
#   - Python 3.9+ with textual and watchdog packages
#
# Exit codes:
#   0 — Claude Code / watchdog session ended normally
#   1 — Claude Code CLI not found
#   2 — Invalid argument combination (e.g. --autonomous on a new project
#       without --brief)
#   3 — Python 3.9+ or TUI dependencies not found
#   4 — A scrum-team tmux session is already running for this project directory
#
# Test hook:
#   SCRUM_START_DRY_RUN=1   Stops just before tmux / claude / watchdog launch.
#                           Autonomous prep (brief copy, config merge,
#                           autonomy.json init) still happens — useful for
#                           integration tests.
#
# Note: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 is set process-scoped
# when launching claude. Users do NOT need to export it globally.
# --- end of help ---
# Re-exec under bash when started as `sh <script>` on a system whose /bin/sh is
# not bash (Linux: dash). Everything below needs bash (pipefail, arrays), and
# the documented launch command is `sh …`, so this keeps that command portable.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Parse CLI flags (Bash 3.2 compatible; no getopts) ----------------------
AUTONOMOUS=0
BRIEF_FILE=""
OPT_MAX_SPRINTS=""
OPT_MAX_HOURS=""
OPT_SM_MODEL=""
SM_MODEL_GIVEN=0
OPT_PO_MODEL=""
PO_MODEL_GIVEN=0
# Raw `--agent-model` specs, newline-separated (Bash 3.2: no arrays needed).
AGENT_MODEL_SPECS=""
BYPASS_PERMS=0
# Distinguish "flag not given" from "flag explicitly set to 0". The interactive
# wizard reads BYPASS_PERMS_GIVEN to decide whether to prompt.
BYPASS_PERMS_GIVEN=0
NO_ATTACH=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --autonomous)         AUTONOMOUS=1; shift ;;
    --brief)
      [ "$#" -ge 2 ] || { echo "Error: --brief requires a file path." >&2; exit 2; }
      BRIEF_FILE="$2"; shift 2 ;;
    --max-sprints)
      [ "$#" -ge 2 ] || { echo "Error: --max-sprints requires a value." >&2; exit 2; }
      OPT_MAX_SPRINTS="$2"; shift 2 ;;
    --max-hours)
      [ "$#" -ge 2 ] || { echo "Error: --max-hours requires a value." >&2; exit 2; }
      OPT_MAX_HOURS="$2"; shift 2 ;;
    --sm-model)
      [ "$#" -ge 2 ] || { echo "Error: --sm-model requires a value." >&2; exit 2; }
      OPT_SM_MODEL="$2"; SM_MODEL_GIVEN=1; shift 2 ;;
    --po-model)
      [ "$#" -ge 2 ] || { echo "Error: --po-model requires a value." >&2; exit 2; }
      OPT_PO_MODEL="$2"; PO_MODEL_GIVEN=1; shift 2 ;;
    --agent-model)
      [ "$#" -ge 2 ] || { echo "Error: --agent-model requires <seat>=[<provider>:]<model>[@<effort>]." >&2; exit 2; }
      AGENT_MODEL_SPECS="${AGENT_MODEL_SPECS}${2}"$'\n'; shift 2 ;;
    --bypass-permissions) BYPASS_PERMS=1; BYPASS_PERMS_GIVEN=1; shift ;;
    --no-attach)          NO_ATTACH=1; shift ;;
    -h|--help)
      # Print the header comment up to the end-of-help marker.
      awk 'NR > 1 && /^# --- end of help ---$/ { exit } { print }' "$0"
      exit 0 ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2 ;;
  esac
done

# Model values are written as unquoted YAML scalars and passed to Claude Code.
# Keep validation deliberately syntactic: aliases/model IDs need only be a
# non-empty, single-line token. Claude CLI remains authoritative for whether a
# syntactically valid alias or ID is actually available to this account.
is_safe_model_token() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

validate_model() {
  local option="$1" value="$2"
  if ! is_safe_model_token "$value"; then
    echo "Error: $option must be a non-empty, single-line model alias or ID" >&2
    echo "  using only letters, digits, '.', '_', '/', and '-'." >&2
    exit 2
  fi
}

if [ "$SM_MODEL_GIVEN" = "1" ]; then
  validate_model "--sm-model" "$OPT_SM_MODEL"
fi
if [ "$PO_MODEL_GIVEN" = "1" ]; then
  validate_model "--po-model" "$OPT_PO_MODEL"
fi

# --- Per-seat model overrides ----------------------------------------------
# Every model flag lands in OVERRIDES_JSON: an object keyed by seat whose
# values are {provider, model, effort?}. `--sm-model X` / `--po-model X` are
# shorthands for `--agent-model scrum-master=claude:X` /
# `--agent-model product-owner=claude:X`. The launcher pre-validates each
# flag against the SOURCE catalog so a typo exits 2 before any side effect;
# the deployed .scrum/scripts/agent-models.sh re-validates authoritatively
# when the table is written (after setup-user.sh deploys it).
MODEL_CATALOG="$SCRIPT_DIR/docs/contracts/model-catalog.json"
OVERRIDES_JSON='{}'

override_seat() {
  # override_seat <flag-label> <seat> <provider|""> <model> <effort|"">
  local flag="$1" seat="$2" provider="$3" model="$4" effort="$5"
  if jq -e --arg s "$seat" 'has($s)' <<<"$OVERRIDES_JSON" >/dev/null; then
    echo "Error: $flag: seat '$seat' is set more than once" \
         "(--agent-model / --sm-model / --po-model overlap)." >&2
    exit 2
  fi
  if ! jq -e --arg s "$seat" '.seats[$s] != null' "$MODEL_CATALOG" >/dev/null; then
    echo "Error: $flag: unknown seat '$seat'. Known seats:" >&2
    jq -r '.seats | to_entries | sort_by(.value.order) | .[] | "  " + .key' \
      "$MODEL_CATALOG" >&2
    exit 2
  fi
  if [ -z "$provider" ]; then
    provider="$(jq -r --arg s "$seat" '.seats[$s].default.provider' "$MODEL_CATALOG")"
  fi
  if ! jq -e --arg s "$seat" --arg p "$provider" \
       '.seats[$s].providers | index($p) != null' "$MODEL_CATALOG" >/dev/null; then
    echo "Error: $flag: provider '$provider' is not allowed for seat '$seat'" \
         "(allowed: $(jq -r --arg s "$seat" '.seats[$s].providers | join(", ")' "$MODEL_CATALOG"))." >&2
    exit 2
  fi
  if [ "$provider" = "codex" ] && [ "$model" = "default" ]; then
    :  # Codex CLI default: stored as null by agent-models.sh.
  elif ! is_safe_model_token "$model" \
       || { [ "$provider" = "codex" ] && [[ "$model" == */* ]]; }; then
    echo "Error: $flag must be a non-empty, single-line model alias or ID" >&2
    echo "  using only letters, digits, '.', '_', and '-' ('/' allowed for claude)." >&2
    exit 2
  fi
  if [ -n "$effort" ] && ! jq -e --arg p "$provider" --arg e "$effort" \
       '(.providers[$p].efforts // []) | index($e) != null' "$MODEL_CATALOG" >/dev/null; then
    echo "Error: $flag: effort '$effort' is not valid for provider '$provider'" \
         "(allowed: $(jq -r --arg p "$provider" '(.providers[$p].efforts // []) | join(", ")' "$MODEL_CATALOG"))." >&2
    exit 2
  fi
  OVERRIDES_JSON="$(jq -c --arg s "$seat" --arg p "$provider" --arg m "$model" --arg e "$effort" \
    '. + {($s): ({provider: $p, model: $m} + (if $e == "" then {} else {effort: $e} end))}' \
    <<<"$OVERRIDES_JSON")"
}

if [ -n "$AGENT_MODEL_SPECS" ]; then
  while IFS= read -r _spec; do
    [ -n "$_spec" ] || continue
    case "$_spec" in
      *=*) : ;;
      *) echo "Error: --agent-model expects <seat>=[<provider>:]<model>[@<effort>], got '$_spec'." >&2
         exit 2 ;;
    esac
    _seat="${_spec%%=*}"; _rest="${_spec#*=}"
    case "$_rest" in
      *:*) _provider="${_rest%%:*}"; _rest="${_rest#*:}" ;;
      *)   _provider="" ;;
    esac
    case "$_rest" in
      *@*) _model="${_rest%%@*}"; _effort="${_rest#*@}" ;;
      *)   _model="$_rest"; _effort="" ;;
    esac
    override_seat "--agent-model $_spec" "$_seat" "$_provider" "$_model" "$_effort"
  done <<EOF
$AGENT_MODEL_SPECS
EOF
fi
if [ "$SM_MODEL_GIVEN" = "1" ]; then
  override_seat "--sm-model" scrum-master claude "$OPT_SM_MODEL" ""
fi
if [ "$PO_MODEL_GIVEN" = "1" ]; then
  override_seat "--po-model" product-owner claude "$OPT_PO_MODEL" ""
fi

# --- Validate prerequisites ---

# shellcheck source=scripts/lib/check-python.sh
. "$SCRIPT_DIR/scripts/lib/check-python.sh"
# shellcheck source=scripts/lib/time.sh
. "$SCRIPT_DIR/scripts/lib/time.sh"
# shellcheck source=scripts/lib/ids.sh
. "$SCRIPT_DIR/scripts/lib/ids.sh"
check_claude_cli
# Version warning lives only in scrum-start.sh (not setup-user.sh) so the
# operator sees the upgrade prompt once per launch rather than twice.
check_claude_cli_version
# Codex is optional; recommend it (non-fatal) so operators know the PBI
# pipeline's cross-model reviewers degrade to a Claude fallback without it.
check_codex_cli
check_python_prereqs

# --- Wizard helpers --------------------------------------------------------
# Skip prompts (return the default) when stdin is not a TTY or when
# SCRUM_START_DRY_RUN is set. This preserves headless launches (cron,
# bats integration tests, piped input) without forcing every caller to
# pass every CLI flag.
prompt_value() {
  # prompt_value <label> <default>
  # Echoes the user's input or the default.
  local label="$1" default="$2" answer
  if [ ! -t 0 ] || [ "${SCRUM_START_DRY_RUN:-0}" = "1" ]; then
    printf '%s' "$default"
    return 0
  fi
  printf '  %s [%s]: ' "$label" "$default" >&2
  IFS= read -r answer || answer=""
  if [ -z "$answer" ]; then
    answer="$default"
  fi
  printf '%s' "$answer"
}

prompt_yes_no() {
  # prompt_yes_no <label> <default>   (default: y or n)
  # Echoes "y" or "n".
  local label="$1" default="$2" answer indicator
  if [ ! -t 0 ] || [ "${SCRUM_START_DRY_RUN:-0}" = "1" ]; then
    printf '%s' "$default"
    return 0
  fi
  case "$default" in
    y) indicator="Y/n" ;;
    *) indicator="y/N" ;;
  esac
  while :; do
    printf '  %s [%s]: ' "$label" "$indicator" >&2
    IFS= read -r answer || answer=""
    if [ -z "$answer" ]; then
      answer="$default"
    fi
    case "$answer" in
      y|Y|yes|YES) printf 'y'; return 0 ;;
      n|N|no|NO)   printf 'n'; return 0 ;;
      *) echo "    Please answer y or n." >&2 ;;
    esac
  done
}

prompt_model_choice() {
  # prompt_model_choice <label> <default>
  # Offers the Claude model menu from docs/contracts/model-catalog.json plus
  # a validated custom model ID. Answer by number or by id. On non-TTY and
  # dry-run launches, simply returns the persisted/default value.
  local label="$1" default="$2" answer custom menu n_menu i id
  if [ ! -t 0 ] || [ "${SCRUM_START_DRY_RUN:-0}" = "1" ]; then
    printf '%s' "$default"
    return 0
  fi
  menu="$(jq -r '.providers.claude.models[].id' "$MODEL_CATALOG")"
  n_menu="$(printf '%s\n' "$menu" | grep -c .)"
  while :; do
    printf '\n%s (current default: %s):\n' "$label" "$default" >&2
    i=0
    while IFS= read -r id; do
      i=$((i + 1))
      printf '  %d) %s\n' "$i" "$id" >&2
    done <<EOF
$menu
EOF
    printf '  %d) custom model ID\n' "$((n_menu + 1))" >&2
    printf '  Choice [Enter keeps %s]: ' "$default" >&2
    IFS= read -r answer || answer=""
    if [ -z "$answer" ]; then
      printf '%s' "$default"
      return 0
    fi
    if [ "$answer" = "custom" ] || [ "$answer" = "$((n_menu + 1))" ]; then
      printf '  Custom model ID: ' >&2
      IFS= read -r custom || custom=""
      if is_safe_model_token "$custom"; then
        printf '%s' "$custom"
        return 0
      fi
      echo "    Enter a non-empty single-line token using letters, digits, '.', '_', '/', or '-'." >&2
      continue
    fi
    i=0
    while IFS= read -r id; do
      i=$((i + 1))
      if [ "$answer" = "$i" ] || [ "$answer" = "$id" ]; then
        printf '%s' "$id"
        return 0
      fi
    done <<EOF
$menu
EOF
    echo "    Choose 1-$((n_menu + 1)) (a listed id, or custom)." >&2
  done
}

# jq_write_inplace <file> <jq_filter> [jq_args...]
# Rewrites <file> in place through jq via a same-directory tmp file so the
# final mv is atomic. Extra args are passed to jq before the filter
# (--arg/--argjson). On jq failure the tmp file is removed and the function
# returns nonzero — fatal under `set -e` unless the caller tests the result.
# Not for `jq -n` producers (no input file); those keep their inline tmp+mv.
jq_write_inplace() {
  local file="$1" filter="$2" tmp
  shift 2
  tmp="${file}.tmp.$$.${RANDOM}"
  if jq "$@" "$filter" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- Prior per-seat model choices (BEFORE setup-user.sh) -------------------
# A project launched before the model table existed carries its last
# --sm-model / --po-model choice only in the deployed agent frontmatter,
# which setup-user.sh is about to overwrite. Import it now by running the
# SOURCE copy of migration 009 (no-op once .agents exists, and on projects
# that never deployed agents); the deployed copy re-runs later under
# migrate-state.sh as a no-op.
# Non-fatal on purpose: the import validates the whole config file, and a
# config that has drifted from the schema must reach the upgrade gate below
# (migrate-state.sh) to be diagnosed, not fail here under a model-import
# message. A skipped import only costs the prior frontmatter choice.
if _seed_out="$(bash "$SCRIPT_DIR/scripts/scrum/migrations/009-seed-agent-models.sh" 2>&1)"; then
  case "$_seed_out" in
    *"seeded agents"*) echo "  $_seed_out" ;;
  esac
else
  echo "Warning: could not import prior model choices from the deployed agent files;" >&2
  echo "  continuing with the persisted table / catalog defaults. Detail:" >&2
  printf '%s\n' "$_seed_out" | sed 's/^/    /' >&2
fi
PRIOR_AGENTS_JSON='{}'
if [ -f ".scrum/config.json" ]; then
  PRIOR_AGENTS_JSON="$(jq -c '.agents | if type == "object" then . else {} end' \
    .scrum/config.json 2>/dev/null || printf '{}')"
fi

seat_model_default() {
  # seat_model_default <seat> → CLI override > persisted table > catalog default
  jq -r --arg s "$1" --argjson o "$OVERRIDES_JSON" --argjson p "$PRIOR_AGENTS_JSON" \
    '$o[$s].model // $p[$s].model // .seats[$s].default.model' "$MODEL_CATALOG"
}

# Wizard: the Scrum Master model in every mode; the Product Owner model in
# autonomous mode. Skipped for a seat already set via CLI. Other seats are
# set only via --agent-model (or the Mac app) — a nine-seat prompt on every
# launch would be noise.
if ! jq -e 'has("scrum-master")' <<<"$OVERRIDES_JSON" >/dev/null; then
  _choice="$(prompt_model_choice 'Scrum Master model' "$(seat_model_default scrum-master)")"
  validate_model "--sm-model" "$_choice"
  override_seat "--sm-model" scrum-master claude "$_choice" ""
fi
if [ "$AUTONOMOUS" = "1" ] && ! jq -e 'has("product-owner")' <<<"$OVERRIDES_JSON" >/dev/null; then
  _choice="$(prompt_model_choice 'Product Owner model' "$(seat_model_default product-owner)")"
  validate_model "--po-model" "$_choice"
  override_seat "--po-model" product-owner claude "$_choice" ""
fi

# --- Run setup (copies agents, skills, hooks, configures settings) ---
bash "$SCRIPT_DIR/scripts/setup-user.sh"

# --- Upgrade gate: migrate state + validate against the deployed schemas ---
# setup-user.sh above just refreshed .scrum/scripts/ and the schemas; existing
# .scrum/ state written under an older framework version must be migrated
# (idempotent migrations, lexical order) and must validate against the new
# schemas BEFORE the team is spawned. Hard-fail: launching agents on drifted
# state produces confusing mid-Sprint failures. Fresh projects (no state
# files yet) flow through as a no-op. Deployed copy on purpose — its schema
# probe resolves against the target project, and it requires bash (sourced
# libs use BASH_SOURCE).
if ! bash .scrum/scripts/migrate-state.sh; then
  echo "" >&2
  echo "ERROR: .scrum state migration/validation failed — NOT launching the team." >&2
  echo "  Inspect:  bash .scrum/scripts/migrate-state.sh --check" >&2
  echo "  Deployed framework rev: .scrum/deploy-stamp.json" >&2
  exit 1
fi

# --- Persist + materialize the per-seat model table ------------------------
# Effective table = catalog defaults ⊕ persisted .agents ⊕ CLI/wizard
# overrides (recursive merge: an override without @<effort> keeps the prior
# or default effort). Written in ONE validated write by the deployed wrapper
# (the sole writer of .agents), then the deployed Claude agent files —
# freshly restored to source defaults by setup-user.sh — get their `model:` /
# `effort:` frontmatter rewritten from the table. Runs after the migrate gate
# so a stale config is migrated before it is validated here.
DEFAULTS_JSON="$(jq -c '.seats | to_entries | sort_by(.value.order)
  | map({(.key): .value.default}) | add' "$MODEL_CATALOG")"
# Persisted seats the current catalog no longer defines are dropped here
# (the wrapper would also drop them with a WARN) so a renamed seat can never
# wedge the launch.
AGENTS_TABLE="$(jq -cn --argjson d "$DEFAULTS_JSON" --argjson p "$PRIOR_AGENTS_JSON" \
  --argjson o "$OVERRIDES_JSON" '$d * ($p | with_entries(select(.key | in($d)))) * $o')"
if ! bash .scrum/scripts/agent-models.sh set-table "$AGENTS_TABLE" >/dev/null; then
  echo "Error: could not persist the per-seat model table (.scrum/config.json.agents)." >&2
  exit 2
fi
echo "Team models (.scrum/config.json.agents):"
bash .scrum/scripts/agent-models.sh materialize
if [ "$PO_MODEL_GIVEN" = "1" ] && [ "$AUTONOMOUS" = "0" ]; then
  echo "  Product Owner model persisted (the PO teammate is spawned only with --autonomous)."
fi

# --- Detect new vs resume and set initial prompt ---
IS_NEW_PROJECT=0
if [ -f ".scrum/state.json" ]; then
  echo ""
  echo "Existing project detected — resuming from saved state."

  phase="$(jq -r '.phase // "unknown"' .scrum/state.json)"
  echo "  Current phase: $phase"
  initial_prompt="Resume the Scrum workflow from the SessionStart resume summary. Do not reread all Scrum state, backlog, or implementation files at startup. If evidence needed for the next decision is missing from the summary, delegate a targeted investigation to scrum-explorer, then continue from the current phase."
else
  IS_NEW_PROJECT=1
  echo ""
  echo "New project — starting fresh."
  mkdir -p .scrum/reviews
  # Bootstrap .scrum/state.json via the deployed wrapper so the SM's first
  # update-state-phase call has a file to mutate. setup-user.sh above has
  # already copied scripts/scrum/*.sh to .scrum/scripts/.
  bash .scrum/scripts/init-state.sh
  initial_prompt="Introduce yourself and begin the Requirement Definition. Greet the user, explain the Scrum workflow briefly. A product brief has been co-authored at docs/product/brief.md — read it first and use it as the anchor for the interview: elicit requirements that realize the brief, and when a requirement conflicts with the brief, surface the conflict and resolve it by amending either the brief or the requirement (do not silently diverge)."
fi

# Brief pre-flight flag. Set to 1 by the brief-resolution blocks below (both
# the autonomous and the human-mode branches) when a new project has no
# docs/product/brief.md yet and a human is present. Initialized here so the
# launch branches can reference it safely under `set -u`.
NEED_BRIEF_BUILDER=0

# --- Autonomous-PO mode preparation ----------------------------------------
# Done before tmux/claude launch so the watchdog finds .scrum/config.json
# and .scrum/autonomy.json in place. Non-autonomous runs hit none of this.

if [ "$AUTONOMOUS" = "1" ]; then
  # Compute prior values for the wizard defaults BEFORE the defaults-merge
  # runs. For settings that live in .scrum/config.json, the prior value is
  # the current key (or the baked-in default when absent). The PO model was
  # already resolved (and persisted in .agents) before setup-user.sh.
  mkdir -p .scrum
  CONFIG_FILE=".scrum/config.json"
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '{}\n' > "$CONFIG_FILE"
  fi
  _cur_max_sprints="$(jq -r '.autonomous.max_sprints // 8' \
    "$CONFIG_FILE" 2>/dev/null || echo 8)"
  _cur_max_hours="$(jq -r '.autonomous.max_wall_clock_hours // 8' \
    "$CONFIG_FILE" 2>/dev/null || echo 8)"
  _cur_perm_mode="$(jq -r '.autonomous.permission_mode // "dontAsk"' \
    "$CONFIG_FILE" 2>/dev/null || echo dontAsk)"
  _cur_bypass="n"
  if [ "$_cur_perm_mode" = "bypassPermissions" ]; then
    _cur_bypass="y"
  fi

  # --- Interactive wizard --------------------------------------------------
  # Only print the banner when at least one prompt will actually fire AND
  # stdin is a TTY (so the user sees it). Helpers themselves return defaults
  # silently on non-TTY / DRY_RUN, so existing scripted runs keep working.
  if [ -t 0 ] && [ "${SCRUM_START_DRY_RUN:-0}" != "1" ]; then
    _wizard_needed=0
    if [ "$IS_NEW_PROJECT" = "1" ] && [ -z "$BRIEF_FILE" ]; then _wizard_needed=1; fi
    if [ -z "$OPT_MAX_SPRINTS" ];   then _wizard_needed=1; fi
    if [ -z "$OPT_MAX_HOURS" ];     then _wizard_needed=1; fi
    if [ "$BYPASS_PERMS_GIVEN" = "0" ]; then _wizard_needed=1; fi
    if [ "$_wizard_needed" = "1" ]; then
      echo "" >&2
      echo "Autonomous mode configuration (press Enter to accept defaults):" >&2
    fi
  fi

  # Brief is the only prompt with no safe non-interactive default: on a new
  # project with no --brief, the run must fail with "requires --brief" so the
  # operator knows to provide one. Only prompt for it when stdin is a TTY
  # (and not under DRY_RUN); the non-TTY path falls through to the existing
  # exit-2 validation below.
  if [ "$IS_NEW_PROJECT" = "1" ] && [ -z "$BRIEF_FILE" ] \
     && [ -t 0 ] && [ "${SCRUM_START_DRY_RUN:-0}" != "1" ]; then
    BRIEF_FILE="$(prompt_value 'Product brief file' 'docs/product/brief.md')"
  fi
  if [ -z "$OPT_MAX_SPRINTS" ]; then
    OPT_MAX_SPRINTS="$(prompt_value 'Maximum number of sprints' "$_cur_max_sprints")"
  fi
  if [ -z "$OPT_MAX_HOURS" ]; then
    OPT_MAX_HOURS="$(prompt_value 'Maximum wall-clock hours' "$_cur_max_hours")"
  fi
  if [ "$BYPASS_PERMS_GIVEN" = "0" ]; then
    _ans="$(prompt_yes_no \
      'Bypass ALL Claude permission prompts (destructive — throwaway worktree only)' \
      "$_cur_bypass")"
    if [ "$_ans" = "y" ]; then
      BYPASS_PERMS=1
    else
      BYPASS_PERMS=0
    fi
  fi

  # --- Brief resolution ----------------------------------------------------
  # A product brief at docs/product/brief.md anchors every scope / YAGNI
  # decision the autonomous PO makes. Resolution order:
  #   1. canonical brief already exists       → use it (resume / re-run).
  #   2. explicit readable --brief file        → copy it into place.
  #   3. explicit --brief path that is missing → hard error (typo).
  #   4. new project, no brief anywhere:
  #        - TTY (human present) → co-author one via the create-brief skill
  #          as a pre-flight step before the watchdog launches (set
  #          NEED_BRIEF_BUILDER; the launch branches below run it first).
  #        - non-TTY (no human)  → hard error; a brief cannot be
  #          co-authored headlessly.
  # The wizard above fills an unset BRIEF_FILE with the canonical default on
  # a TTY, so "BRIEF_FILE == canonical but the file is absent" is the
  # no-brief-yet case and routes to the builder, not to the typo error.
  BRIEF_CANONICAL="docs/product/brief.md"
  if [ -f "$BRIEF_CANONICAL" ]; then
    # Canonical brief already present — never clobber it.
    if [ -n "$BRIEF_FILE" ] && [ "$BRIEF_FILE" != "$BRIEF_CANONICAL" ] \
       && [ -f "$BRIEF_FILE" ]; then
      echo "Warning: $BRIEF_CANONICAL already exists — keeping existing copy" \
           "(ignoring --brief $BRIEF_FILE)." >&2
    fi
  elif [ -n "$BRIEF_FILE" ] && [ "$BRIEF_FILE" != "$BRIEF_CANONICAL" ] \
       && [ -f "$BRIEF_FILE" ]; then
    # Explicit, readable brief provided — copy into the canonical location.
    mkdir -p docs/product
    cp "$BRIEF_FILE" "$BRIEF_CANONICAL"
    echo "  Copied brief to $BRIEF_CANONICAL"
  elif [ -n "$BRIEF_FILE" ] && [ "$BRIEF_FILE" != "$BRIEF_CANONICAL" ]; then
    # Explicit non-canonical path that does not exist — almost certainly a
    # typo. Fail loudly rather than silently co-authoring a new brief.
    echo "Error: brief file not found: $BRIEF_FILE" >&2
    exit 2
  elif [ "$IS_NEW_PROJECT" = "1" ]; then
    # New project with no brief. Co-author one if a human is present;
    # otherwise this run cannot proceed.
    if [ -t 0 ] && [ "${SCRUM_START_DRY_RUN:-0}" != "1" ]; then
      NEED_BRIEF_BUILDER=1
      echo "  No product brief found — will co-author $BRIEF_CANONICAL with" \
           "Claude (create-brief skill) before the autonomous run starts."
    else
      echo "Error: --autonomous on a new project requires --brief <file>." >&2
      echo "  Provide a product brief, or run interactively (a TTY) so the" >&2
      echo "  create-brief skill can co-author docs/product/brief.md with you." >&2
      exit 2
    fi
  fi

  # Resolve permission_mode (after the wizard may have toggled BYPASS_PERMS).
  if [ "$BYPASS_PERMS" = "1" ]; then
    PERM_MODE="bypassPermissions"
  else
    PERM_MODE="dontAsk"
  fi

  # Defaults match .scrum-config.example.json. Overrides applied last.
  # Models are not here: the per-seat table `.agents` was already written
  # above by agent-models.sh and this in-place merge leaves it untouched.
  # shellcheck disable=SC2016  # $perm is a jq --arg binding, not shell
  jq_write_inplace "$CONFIG_FILE" '
    .po_mode = "agent"
    | .autonomous = (
        (.autonomous // {})
        + {
            max_iterations:            (.autonomous.max_iterations            // 50),
            max_wall_clock_hours:      (.autonomous.max_wall_clock_hours      // 8),
            max_sprints:               (.autonomous.max_sprints               // 8),
            max_consecutive_failures:  (.autonomous.max_consecutive_failures  // 3),
            stop_block_budget_per_phase: (.autonomous.stop_block_budget_per_phase // 8),
            permission_mode:           $perm,
            notify_command:            (.autonomous.notify_command            // null),
            fallback_model:            (.autonomous.fallback_model            // null)
          }
      )
  ' --arg perm "$PERM_MODE"

  # Apply --max-sprints / --max-hours overrides (CLI value or wizard input).
  if [ -n "$OPT_MAX_SPRINTS" ]; then
    # shellcheck disable=SC2016  # $v is a jq --argjson binding, not shell
    jq_write_inplace "$CONFIG_FILE" '.autonomous.max_sprints = $v' \
      --argjson v "$OPT_MAX_SPRINTS"
  fi
  if [ -n "$OPT_MAX_HOURS" ]; then
    # shellcheck disable=SC2016  # $v is a jq --argjson binding, not shell
    jq_write_inplace "$CONFIG_FILE" '.autonomous.max_wall_clock_hours = $v' \
      --argjson v "$OPT_MAX_HOURS"
  fi

  # Initialise .scrum/autonomy.json. UUID via shared scripts/lib/ids.sh.
  RUN_ID="$(generate_uuid)"
  NOW_ISO="$(iso_utc_now)"
  cat > .scrum/autonomy.json <<EOF
{
  "run_id": "$RUN_ID",
  "started_at": "$NOW_ISO",
  "lead_session_id": null,
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null,
  "updated_at": "$NOW_ISO"
}
EOF
  echo "  Autonomous PO mode prepared (run_id=$RUN_ID)."
else
  # --- Non-autonomous (human) mode: neutralize leftover autonomous config ---
  # A prior `--autonomous` run persists `po_mode = "agent"` in
  # .scrum/config.json. Without this reset, a plain `scrum-start.sh` would
  # inherit it and the SM would spawn the product-owner teammate. `po_mode`
  # is the single authoritative switch (autonomy_enabled() requires it), so
  # flipping it back to "human" fully restores human-PO behavior — no PO is
  # spawned and the autonomous Stop-gate/hook paths all no-op. The
  # `.autonomous.*` tuning block is left intact for the next autonomous run.
  # Written directly (not via a .scrum/scripts wrapper) for the same reason
  # the autonomous branch above does: this runs in the launcher, outside any
  # agent tool call, so the scrum-state-guard hook never intercepts it.
  RESET_CFG=".scrum/config.json"
  if [ -f "$RESET_CFG" ]; then
    _prior_po_mode="$(jq -r '.po_mode // "human"' "$RESET_CFG" 2>/dev/null || echo human)"
    if [ "$_prior_po_mode" = "agent" ]; then
      if jq_write_inplace "$RESET_CFG" '.po_mode = "human"' 2>/dev/null; then
        echo "  Human mode: reset leftover po_mode=agent → human (PO teammate disabled)."
      else
        echo "Warning: could not reset po_mode in $RESET_CFG (continuing)." >&2
      fi
    fi
  fi

  # --- Brief pre-flight (human mode) --------------------------------------
  # A product brief at docs/product/brief.md anchors Requirement Definition in
  # human mode exactly as it anchors the PO's scope decisions in autonomous
  # mode. On a new project with no brief and a human present (TTY), co-author
  # one via the create-brief skill before the Scrum Master session starts —
  # this makes "brief first" the very first thing the human does, mirroring the
  # autonomous pre-flight. Non-TTY / DRY_RUN runs (tests, scripted launches)
  # fall through with NEED_BRIEF_BUILDER=0 and behave as before.
  if [ "$IS_NEW_PROJECT" = "1" ] && [ ! -f "docs/product/brief.md" ] \
     && [ -t 0 ] && [ "${SCRUM_START_DRY_RUN:-0}" != "1" ]; then
    NEED_BRIEF_BUILDER=1
    echo "  No product brief found — will co-author docs/product/brief.md with" \
         "Claude (create-brief skill) before Requirement Definition begins."
  fi
fi

# --- Launch ---
echo ""

# Build the autonomous launch command (used by both tmux and no-tmux branches).
WATCHDOG_CMD="$SCRIPT_DIR/scripts/autonomous/watchdog.sh"

# Pre-flight brief builder (set by the brief-resolution block above). When no
# brief exists on a new autonomous project and a human is present, an
# interactive Claude session co-authors docs/product/brief.md via the
# create-brief skill before the watchdog starts. Kept apostrophe-free so it
# can be single-quoted safely inside the tmux send-keys command string.
if [ "$AUTONOMOUS" = "1" ]; then
  BRIEF_BUILDER_TAIL="autonomous mode will start as soon as I exit this session."
else
  BRIEF_BUILDER_TAIL="the Scrum team will begin Requirement Definition as soon as I exit this session."
fi
BRIEF_BUILDER_PROMPT="A product brief is required before the Scrum team can start, but docs/product/brief.md does not exist yet. Use the create-brief skill now to co-author the brief with me interactively. Interview me one topic at a time, quality-gate the draft, and write the result to docs/product/brief.md. When the brief is complete, tell me it is done and that ${BRIEF_BUILDER_TAIL}"

# run_brief_builder_or_abort <abort_message>
# No-tmux pre-flight: co-author docs/product/brief.md via the create-brief
# skill (interactive Claude), then hard-exit (2) if the user left without
# writing one. <abort_message> is the mode-specific error tail. Shared by the
# autonomous and human no-tmux launch branches.
run_brief_builder_or_abort() {
  echo "No product brief found — launching the brief builder (create-brief skill)..."
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude "$BRIEF_BUILDER_PROMPT"
  if [ ! -f docs/product/brief.md ]; then
    echo "Error: no brief was created — $1" >&2
    exit 2
  fi
}

# brief_builder_tmux_cmd <abort_message>
# Emits (on stdout) the tmux pre-flight command prefix that co-authors the
# brief and, if the user exits without one, prints the mode-specific abort
# message and kills the session. Shared by the autonomous and human tmux
# launch branches (uses the global $session_name, in scope at call time).
brief_builder_tmux_cmd() {
  printf "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude '%s'; if [ ! -f docs/product/brief.md ]; then echo; echo 'No brief was created — %s  Press Enter to close.'; read -r; tmux kill-session -t %s; exit 0; fi; " \
    "$BRIEF_BUILDER_PROMPT" "$1" "$session_name"
}

# SCRUM_NO_TMUX=1 forces the no-tmux foreground branch even when tmux is
# installed. The macOS app (macapp/) sets this so the Scrum Master runs in
# the foreground of an embedded SwiftTerm pane; the app supplies its own
# layout (dashboard is launched separately in its own pane).
if [ "${SCRUM_NO_TMUX:-0}" != "1" ] && command -v tmux >/dev/null 2>&1; then
  # tmux available — create the session, optionally with a split dashboard
  #
  # Session name is derived from the project directory so that concurrent
  # scrum-start.sh runs in *different* projects coexist on a single tmux
  # server. The hash disambiguates projects that share a basename. A run
  # inside the *same* project refuses to clobber the existing session
  # below — the user must close or attach explicitly, since silently
  # killing it has previously destroyed the predecessor's running Claude
  # session without warning.
  pwd_hash="$(printf '%s' "$PWD" | portable_sha1 | cut -c1-8)"
  raw_basename="$(basename "$PWD")"
  session_basename="$(printf '%s' "$raw_basename" | tr -c 'A-Za-z0-9_-' '_')"
  session_name="scrum-team-${session_basename}-${pwd_hash}"

  min_split_cols=120
  # tput cols inside $(...) loses tty detection on macOS — stdout is a pipe,
  # so tput falls back to terminfo's default cols (80) instead of querying
  # the controlling terminal. stty size </dev/tty reads from the actual
  # controlling tty regardless of stdin/stdout redirection, so the dashboard
  # split threshold compares against the real terminal width.
  if size_str="$(stty size </dev/tty 2>/dev/null)"; then
    term_lines="${size_str%% *}"
    term_cols="${size_str##* }"
  else
    term_lines=0
    term_cols=0
  fi

  # Refuse to start when a session for this project already exists.
  # Covers both "another terminal is running it" and "stale session from a
  # crashed previous run." User picks attach or kill.
  if tmux has-session -t "=${session_name}" 2>/dev/null; then
    echo "Error: a scrum-team tmux session is already running for this project." >&2
    echo "  Session: ${session_name}" >&2
    echo "  Project: ${PWD}" >&2
    echo "" >&2
    echo "Attach to it:  tmux attach-session -t ${session_name}" >&2
    echo "Or kill it:    tmux kill-session -t ${session_name}" >&2
    exit 4
  fi

  # Tmux truecolor: ensure the dashboard pane sees a 256-color TERM and that
  # tmux passes through 24-bit RGB escape sequences. Without this, tmux
  # defaults to TERM=screen (8 colors) inside the pane, which makes Textual
  # render the dashboard nearly monochrome on Apple Terminal. The flags are
  # idempotent and harmless on tmux servers that already have these set.
  tmux set-option -g default-terminal "screen-256color" 2>/dev/null || true
  tmux set-option -ga terminal-overrides ",*:RGB" 2>/dev/null || true

  # Both branches announce the same main pane; only the dashboard lines differ.
  if [ "$term_cols" -ge "$min_split_cols" ]; then
    echo "Launching Scrum team with tmux dashboard..."
  else
    echo "Launching Scrum team in tmux..."
  fi
  if [ "$AUTONOMOUS" = "1" ]; then
    echo "  Main pane: Autonomous-PO watchdog (Ralph Loop)"
  else
    echo "  Main pane: Claude Code (Scrum Master)"
  fi
  if [ "$term_cols" -ge "$min_split_cols" ]; then
    echo "  Side pane: TUI Dashboard"
  else
    echo "  Dashboard: skipped (terminal width ${term_cols} < ${min_split_cols})"
    echo "  Resize to at least ${min_split_cols} columns to enable the split dashboard."
  fi
  echo ""

  # Dry-run hook for integration tests.
  if [ "${SCRUM_START_DRY_RUN:-0}" = "1" ]; then
    if [ "$AUTONOMOUS" = "1" ]; then
      echo "DRY RUN: would launch watchdog: $WATCHDOG_CMD"
    else
      echo "DRY RUN: would launch claude --agent scrum-master --teammate-mode in-process"
    fi
    echo "DRY RUN: would create tmux session: $session_name"
    [ "$NO_ATTACH" = "1" ] && echo "DRY RUN: --no-attach: would skip tmux attach-session"
    exit 0
  fi

  tmux new-session -d -s "$session_name" -c "$PWD" -x "$term_cols" -y "$term_lines"

  # Resolve the SM pane id (first pane of the freshly-created window). This
  # is captured BEFORE any split so a later split-window for the dashboard
  # does not move the SM pane id underfoot. We also persist tmux_session and
  # started_at so external observers (the stall-watchdog daemon below, the
  # dashboard) can find them. stall_watchdog_pid is filled in after launch
  # for the non-autonomous branch; null when autonomous mode owns liveness.
  SM_PANE_ID="$(tmux display-message -p -t "${session_name}:0.0" '#{pane_id}' 2>/dev/null || echo "")"

  mkdir -p .scrum
  RUNTIME_NOW="$(iso_utc_now)"
  RUNTIME_TMP=".scrum/runtime.json.tmp.$$.${RANDOM}"
  jq -n \
    --arg session "$session_name" \
    --arg pane "$SM_PANE_ID" \
    --arg started "$RUNTIME_NOW" \
    '{
      tmux_session: $session,
      sm_pane_id: $pane,
      started_at: $started,
      stall_watchdog_pid: null
    }' > "$RUNTIME_TMP"
  mv "$RUNTIME_TMP" .scrum/runtime.json

  if [ "$AUTONOMOUS" = "1" ]; then
    # Autonomous mode: main pane runs the watchdog. We deliberately keep the
    # pane alive after the watchdog exits (read -r) so the user can attach in
    # the morning, inspect the report, and decide whether to kill the session.
    #
    # When NEED_BRIEF_BUILDER is set, prepend an interactive Claude session
    # that co-authors docs/product/brief.md (create-brief skill). The watchdog
    # only starts once the brief exists; if the user exits without writing one,
    # the launch aborts cleanly instead of running the PO with no anchor.
    if [ "$NEED_BRIEF_BUILDER" = "1" ]; then
      AUTO_MAIN_CMD="$(brief_builder_tmux_cmd 'aborting autonomous launch.')"
    else
      AUTO_MAIN_CMD=""
    fi
    AUTO_MAIN_CMD="${AUTO_MAIN_CMD}${WATCHDOG_CMD}; echo; echo 'Watchdog exited.  Press Enter to close.'; read -r; tmux kill-session -t ${session_name}"
    tmux send-keys -t "$session_name" "$AUTO_MAIN_CMD" C-m
  else
    # Main pane: Claude Code with Scrum Master agent (Agent Teams enabled
    # process-scoped). --teammate-mode in-process forces Agent Teams to use
    # in-process mode for teammates (Shift+Down to cycle) instead of creating
    # split panes that would overwrite the dashboard pane. The positional
    # argument starts an interactive session with an initial prompt (unlike
    # -p which exits). When Claude exits, the tmux session is killed
    # automatically.
    # When NEED_BRIEF_BUILDER is set, prepend an interactive Claude session
    # that co-authors docs/product/brief.md (create-brief skill) before the
    # Scrum Master starts. If the user exits without writing a brief, abort the
    # launch cleanly rather than starting Requirement Definition with no anchor
    # (mirrors the autonomous pre-flight).
    SM_MAIN_CMD=""
    if [ "$NEED_BRIEF_BUILDER" = "1" ]; then
      SM_MAIN_CMD="$(brief_builder_tmux_cmd 'aborting launch.')"
    fi
    SM_MAIN_CMD="${SM_MAIN_CMD}CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --agent scrum-master --teammate-mode in-process '${initial_prompt}'; tmux kill-session -t ${session_name}"
    tmux send-keys -t "$session_name" "$SM_MAIN_CMD" C-m

    # External stall watchdog (non-autonomous mode only). Replaces the
    # legacy SM-side Stop-hook block-loop. Detached so it survives this
    # shell. Autonomous mode skips this because the Ralph Loop watchdog
    # already owns liveness/safety.
    STALL_WATCHDOG_SCRIPT="$SCRIPT_DIR/scripts/stall-watchdog.sh"
    if [ -x "$STALL_WATCHDOG_SCRIPT" ]; then
      nohup "$STALL_WATCHDOG_SCRIPT" "$PWD" >/dev/null 2>&1 &
      STALL_WATCHDOG_PID=$!
      # Update runtime.json with the pid (best-effort; failure not fatal).
      # shellcheck disable=SC2016  # $pid is a jq --argjson binding, not shell
      jq_write_inplace .scrum/runtime.json '.stall_watchdog_pid = $pid' \
        --argjson pid "$STALL_WATCHDOG_PID" 2>/dev/null || true
    fi
  fi

  if [ "$term_cols" -ge "$min_split_cols" ]; then
    # Side pane: Textual TUI dashboard.
    # COLORTERM=truecolor signals Rich/Textual to emit 24-bit RGB escapes;
    # the tmux terminal-overrides above let those escapes through to the
    # outer terminal so theme colors render with full contrast.
    tmux split-window -h -c "$PWD" -t "$session_name" \
      "COLORTERM=truecolor python3 \"$SCRIPT_DIR/dashboard/app.py\"; read -r"
  fi

  # Focus main pane
  tmux select-pane -t "$session_name":0.0

  if [ "$NO_ATTACH" = "1" ]; then
    echo "Detached: session '$session_name' is running in the background."
    echo "Attach with:  tmux attach-session -t $session_name"
  else
    # Attach to session
    tmux attach-session -t "$session_name"
  fi
else
  # No tmux — use status line only
  echo "Info: tmux not found — using compact status line dashboard." >&2
  echo "Install tmux for a richer view." >&2
  echo ""

  if [ "${SCRUM_START_DRY_RUN:-0}" = "1" ]; then
    if [ "$AUTONOMOUS" = "1" ]; then
      echo "DRY RUN: would launch watchdog: $WATCHDOG_CMD"
    else
      echo "DRY RUN: would launch claude --agent scrum-master"
    fi
    exit 0
  fi

  if [ "$AUTONOMOUS" = "1" ]; then
    # Pre-flight brief co-authoring (see the tmux branch for rationale).
    if [ "$NEED_BRIEF_BUILDER" = "1" ]; then
      run_brief_builder_or_abort "aborting autonomous launch."
    fi
    echo "Launching autonomous-PO watchdog (no tmux fallback)..."
    "$WATCHDOG_CMD"
  else
    # Pre-flight brief co-authoring (human mode; see the tmux branch above).
    if [ "$NEED_BRIEF_BUILDER" = "1" ]; then
      run_brief_builder_or_abort "aborting launch."
    fi
    echo "Launching Claude Code with Scrum Master agent..."
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --agent scrum-master "$initial_prompt"
  fi
fi
