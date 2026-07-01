#!/usr/bin/env bash
# Markdown / shell backticks in literal prompts are not parameter
# expansions; silence the noisy SC2016 warnings file-wide (the directive
# must precede the first command to apply to the whole file).
# shellcheck disable=SC2016
# scripts/autonomous/watchdog.sh — autonomous-PO outer loop (Ralph Loop).
#
# Repeatedly launches a headless `claude -p` Scrum Master session per
# iteration. Each session runs until the Stop hook releases (typically when
# the workflow phase advances or a checkpoint is reached); on process exit
# control returns here. The watchdog enforces global safety bounds (max
# iterations / wall clock / sprints / consecutive failures) and, on API
# rate-limit / usage-limit hits, sleeps until the limit resets and resumes
# automatically. Cost (USD) is recorded for observability but not enforced
# — spend caps are expected to live in the user's Claude subscription plan.
#
# Usage: scripts/autonomous/watchdog.sh
#   Reads `.scrum/config.json`.autonomous and `.scrum/autonomy.json` (which
#   must already exist — produced by scrum-start.sh --autonomous).
#
# Exit codes:
#   0 — workflow phase reached `complete`
#   1 — consecutive failures exceeded threshold
#   2 — safety valve tripped (iterations / wall clock / sprints)
#   3 — configuration error (missing autonomy.json, etc.)
#
# Test hooks (env vars; harmless in production):
#   AUTON_CLAUDE_BIN     — claude binary (default `claude`)
#   AUTON_SLEEP_SCALE    — multiplier on every sleep duration (default 1; 0
#                          disables sleeping entirely — useful for tests)
#   AUTON_NOW_CMD        — command emitting epoch seconds for the "now"
#                          comparison points (default `date +%s`)
#
# Bash 3.2 compatible. shellcheck clean.
#
# Note on --teammate-mode:
#   The `--teammate-mode in-process` flag is undocumented in `claude --help`
#   but is accepted by the CLI (verified 2026-06: `claude --teammate-mode
#   in-process --version` exits 0). The interactive `scrum-start.sh` uses
#   it. For headless `-p` sessions we currently rely on the default mode and
#   omit the flag — there is no behavioural reason to force in-process mode
#   when no human is attached to the tmux pane, and using only documented
#   flags reduces breakage risk if the flag is ever removed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/report.sh
. "$SCRIPT_DIR/lib/report.sh"

# --- Configurable test hooks --------------------------------------------------
AUTON_CLAUDE_BIN="${AUTON_CLAUDE_BIN:-claude}"
AUTON_SLEEP_SCALE="${AUTON_SLEEP_SCALE:-1}"
AUTON_NOW_CMD="${AUTON_NOW_CMD:-date +%s}"

# --- Files -------------------------------------------------------------------
CONFIG_FILE=".scrum/config.json"
AUTONOMY_FILE=".scrum/autonomy.json"
STATE_FILE=".scrum/state.json"
SPRINT_HISTORY_FILE=".scrum/sprint-history.json"
BACKLOG_FILE=".scrum/backlog.json"
DASHBOARD_FILE=".scrum/dashboard.json"
ITER_OUT_DIR=".scrum/autonomous"

# --- Defaults (mirrored from .scrum-config.example.json) ---------------------
DEFAULT_MAX_ITERATIONS=50
DEFAULT_MAX_WALL_HOURS=8
DEFAULT_MAX_SPRINTS=8
DEFAULT_MAX_CONSECUTIVE_FAILURES=3
DEFAULT_PERMISSION_MODE="dontAsk"

# Rate-limit handling: when a session ends because Claude returned a
# rate-limit / usage-limit / overload error, watchdog sleeps until the
# advertised reset time (if parseable from the error payload) or
# `DEFAULT_RATE_LIMIT_WAIT_SECS` otherwise, then retries. There is no
# streak ceiling — the loop waits indefinitely; wall-clock / iteration
# safety valves remain the ultimate runaway protection.
DEFAULT_RATE_LIMIT_WAIT_SECS=3600
# Maximum sleep applied even if a reset time parses to something further
# out (parser sanity cap).
MAX_RATE_LIMIT_WAIT_SECS=21600

# --- Helpers ----------------------------------------------------------------

now_epoch() {
  eval "$AUTON_NOW_CMD"
}

iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

# do_sleep <seconds>
# Sleeps for <seconds> * AUTON_SLEEP_SCALE. When the product is 0 (e.g. in
# tests with AUTON_SLEEP_SCALE=0) we skip sleep entirely.
do_sleep() {
  local secs="$1"
  local effective
  effective="$(awk -v s="$secs" -v m="$AUTON_SLEEP_SCALE" 'BEGIN{print s*m}')"
  case "$effective" in
    0|0.0|0.00|"") return 0 ;;
  esac
  # awk produces a float; sleep accepts both ints and floats on GNU and BSD.
  sleep "$effective" 2>/dev/null || true
}

# Bash 3.2-compatible UUID v4 generator (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx).
generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  # Fallback: synthesize from /dev/urandom hex.
  local hex
  hex="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [ -z "$hex" ] || [ "${#hex}" -lt 32 ]; then
    # Last-resort fallback (deterministic-ish): epoch + pid + RANDOM
    hex="$(printf '%08x%04x%04x%04x%012x' \
      "$(now_epoch)" "$$" "$RANDOM" "$RANDOM" "$RANDOM")"
    hex="${hex:0:32}"
  fi
  # Force version=4 and variant=10xx
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "8" "${hex:17:3}" "${hex:20:12}"
}

# cfg_value <jq_path> <default>
# Reads a scalar from .scrum/config.json with fall-through-to-default on
# missing file / invalid JSON / missing key / null. NO type validation —
# callers that need numeric / enum guarantees must validate the returned
# string themselves. (Historical name: cfg_num; the function never
# enforced integer typing and was being used for both numeric limits and
# the string-valued permission_mode.)
cfg_value() {
  local path="$1" default="$2" val
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  val="$(jq -r "$path // empty" "$CONFIG_FILE" 2>/dev/null || true)"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$val"
}

# cfg_str_or_null <jq_path>
cfg_str_or_null() {
  local path="$1" val
  if [ ! -f "$CONFIG_FILE" ]; then
    return 0
  fi
  val="$(jq -r "$path // empty" "$CONFIG_FILE" 2>/dev/null || true)"
  [ "$val" = "null" ] && val=""
  printf '%s' "$val"
}

# autonomy_atomic_write <jq_expr>
autonomy_atomic_write() {
  local expr="$1" tmp
  tmp="${AUTONOMY_FILE}.tmp.$$.${RANDOM}"
  if jq "$expr" "$AUTONOMY_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$AUTONOMY_FILE"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# progress_hash — emits sha of phase + current_sprint_id + every PBI's id:status.
progress_hash() {
  local body=""
  local phase sid items
  phase="$(_jq_safe "$STATE_FILE" '.phase // ""' '')"
  sid="$(_jq_safe "$STATE_FILE" '.current_sprint_id // ""' '')"
  if [ -f "$BACKLOG_FILE" ] && jq empty "$BACKLOG_FILE" >/dev/null 2>&1; then
    items="$(jq -r '(.items // [])[] | (.id // "") + ":" + (.status // "")' \
      "$BACKLOG_FILE" 2>/dev/null | sort)"
  else
    items=""
  fi
  body="${phase}|${sid}|${items}"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$body" | shasum | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$body" | sha1sum | awk '{print $1}'
  else
    printf '%s' "$body" | cksum | awk '{print $1}'
  fi
}

# iter_is_rate_limit_error <iter_stdout_path>
# Returns 0 if the captured `claude -p` JSON output indicates the session
# ended because the API rate limit / usage limit / overload error fired.
# Matches both the result envelope `subtype` (e.g. `error_rate_limit`,
# `error_usage_limit_exceeded`) and the human-readable `errors[]` strings
# emitted by the CLI for the same conditions.
iter_is_rate_limit_error() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq empty "$f" >/dev/null 2>&1 || return 1
  local is_err subtype errs
  is_err="$(jq -r '.is_error // false' "$f" 2>/dev/null || true)"
  subtype="$(jq -r '.subtype // ""' "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  errs="$(jq -r '(.errors // []) | map(tostring) | join(" ")' "$f" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' || true)"
  case "$subtype" in
    *rate*limit*|*usage*limit*|*overload*|*429*|*too*many*) return 0 ;;
  esac
  if [ "$is_err" = "true" ]; then
    case "$errs" in
      *rate*limit*|*usage*limit*|*overload*|*429*|*too*many*) return 0 ;;
    esac
  fi
  return 1
}

# extract_rate_limit_reset_epoch <iter_stdout_path>
# Best-effort: scans the result JSON's errors[] strings for a reset time
# and emits the unix epoch seconds when the limit is expected to clear.
# Recognised forms (all case-insensitive):
#   - ISO 8601 timestamp: 2026-06-13T15:00:00Z
#   - "reset(s) in N (hour|minute|second)s?"
#   - 10-digit unix epoch (interpreted as seconds)
# Returns non-zero (and prints nothing) if no match is confidently parsed —
# the caller should fall back to DEFAULT_RATE_LIMIT_WAIT_SECS.
extract_rate_limit_reset_epoch() {
  local file="$1"
  [ -f "$file" ] || return 1
  jq empty "$file" >/dev/null 2>&1 || return 1
  local errs
  errs="$(jq -r '(.errors // []) | map(tostring) | join(" ")' "$file" 2>/dev/null || true)"
  [ -n "$errs" ] || return 1

  # 1. ISO 8601 timestamp.
  local iso e
  iso="$(printf '%s' "$errs" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
    | head -1 || true)"
  if [ -n "$iso" ]; then
    e="$(date -u -d "$iso" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
      || echo 0)"
    if [ "${e:-0}" -gt 0 ]; then
      printf '%s\n' "$e"
      return 0
    fi
  fi

  # 2. "reset(s)? in N hour|minute|second(s)?"
  local rel num unit
  rel="$(printf '%s' "$errs" \
    | grep -iEo 'reset[s]?[[:space:]]+in[[:space:]]+[0-9]+[[:space:]]*(hour|minute|second)s?' \
    | head -1 || true)"
  if [ -n "$rel" ]; then
    num="$(printf '%s' "$rel" | grep -oE '[0-9]+' | head -1)"
    unit="$(printf '%s' "$rel" | grep -ioE '(hour|minute|second)' | head -1 \
      | tr '[:upper:]' '[:lower:]')"
    case "$unit" in
      hour)   num=$((num * 3600)) ;;
      minute) num=$((num * 60)) ;;
      second) ;;
    esac
    if [ "${num:-0}" -gt 0 ]; then
      printf '%s\n' "$(($(now_epoch) + num))"
      return 0
    fi
  fi

  # 3. 10-digit unix epoch (Retry-After / X-RateLimit-Reset style).
  local ep
  ep="$(printf '%s' "$errs" | grep -oE '\b1[6-9][0-9]{8}\b' | head -1 || true)"
  if [ -n "$ep" ]; then
    printf '%s\n' "$ep"
    return 0
  fi

  return 1
}

# rate_limited_since <epoch>
# Returns 0 if dashboard.json contains a stop_failure event newer than the
# given start epoch whose reason matches rate_limit / limit / overloaded.
rate_limited_since() {
  local since_epoch="$1"
  [ -f "$DASHBOARD_FILE" ] || return 1
  jq empty "$DASHBOARD_FILE" >/dev/null 2>&1 || return 1
  # Convert each event's timestamp into epoch using date; portable across
  # GNU/BSD by allowing the parser to fail (returns 0 then, treated as old).
  # We do the comparison in awk on the side of robustness.
  local matches
  matches="$(jq -r --argjson since "$since_epoch" '
    (.events // [])
    | map(select((.type // "") == "stop_failure"))
    | map(select(((.detail // .reason // "") | ascii_downcase)
        | test("rate.?limit|overload|too.?many")))
    | .[].timestamp // empty
  ' "$DASHBOARD_FILE" 2>/dev/null || true)"
  [ -n "$matches" ] || return 1

  local ts epoch
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    # GNU date `--date` and BSD `-jf` differ; try GNU first, then BSD.
    epoch="$(date -u -d "$ts" +%s 2>/dev/null || \
             date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)"
    if [ "$epoch" -ge "$since_epoch" ]; then
      return 0
    fi
  done <<EOF
$matches
EOF
  return 1
}

# build_prompt <phase>
# Generates the per-iteration prompt fed to claude -p. The common preamble
# announces the autonomous context; the per-phase tail nudges the SM toward
# the right ceremony / handler.
build_prompt() {
  local phase="$1"
  local preamble tail
  preamble='AUTONOMOUS PO MODE: no human is present. po_mode=agent — every PO decision must be delegated to the product-owner teammate (Liveness Protocol). Read .scrum/state.json, .scrum/autonomy.json, .scrum/backlog.json, and .scrum/sprint.json before deciding. Operate as Scrum Master in Delegate mode. The Stop hook will release you when the workflow phase advances or a checkpoint is reached; do not stop early.'

  case "$phase" in
    ""|new|unknown)
      tail='No state.json yet — bootstrap: read docs/product/brief.md, then drive the Requirement Definition with the product-owner teammate as the user proxy. Aim for `phase=backlog_created` this iteration.'
      ;;
    requirements_sprint)
      tail='Continue the Requirement Definition. Drive elicitation through the product-owner teammate (no human prompts). When complete, transition to `backlog_created`.'
      ;;
    backlog_created)
      tail='Run Sprint Planning. Select the next batch of PBIs with the product-owner teammate and transition to `pbi_pipeline_active`.'
      ;;
    sprint_planning)
      tail='Finalise Sprint Planning. Spawn the developer teammates and transition to `pbi_pipeline_active`.'
      ;;
    pbi_pipeline_active)
      tail='PBI pipeline active. The previous session has exited and any in-process teammates have been destroyed — for every PBI in `in_progress_*`, re-spawn the responsible developer via Liveness Protocol (and, if po_mode=agent, re-spawn the product-owner teammate as well). Resume the PBI conductor loop until all PBIs are merged.'
      ;;
    review|sprint_review)
      tail='Run Sprint Review with the product-owner teammate, then drive Retrospective. After retrospective is recorded, transition either to `sprint_planning` (next Sprint) or, when the Product Goal is satisfied, to `integration_sprint`.'
      ;;
    retrospective)
      tail='Finish the Retrospective if not already recorded (improvements + sprint-history). Then run the sprint-continuation handshake: send the product-owner teammate a PO_DECISION_REQUEST kind=sprint_continuation options=[next_sprint,integration_sprint,complete] and advance the phase per the reply — next_sprint → backlog_created, integration_sprint → integration_sprint, complete → complete. Do NOT end the turn with phase still `retrospective`.'
      ;;
    integration_sprint)
      tail='Drive the Integration Sprint. Run product-wide QA / smoke tests. On defects, transition back to `backlog_created` (defect-fix loop). On pass, transition to `complete`.'
      ;;
    complete)
      tail='Workflow is complete. Verify .scrum/state.json reflects this and stop.'
      ;;
    *)
      tail='Continue the current ceremony for phase `'"$phase"'`. Drive PO decisions through the product-owner teammate.'
      ;;
  esac

  printf '%s\n\n%s\n' "$preamble" "$tail"
}

# _jq_safe is provided by lib/report.sh, sourced unconditionally near the
# top of this script (the `. "$SCRIPT_DIR/lib/report.sh"` line), so it is
# already in scope for every call site here. No local copy needed.

# print_startup_banner
# One-shot ASCII banner that announces autonomous mode and steers the
# operator's eye to the right tmux pane (Textual dashboard), where live
# PBI / work-log state is rendered. This pane (watchdog) only emits at
# iteration boundaries — claude -p stdout is file-logged, not streamed —
# so without the banner the pane looks frozen and users miss that the
# dashboard is the place to watch.
print_startup_banner() {
  # Figlet-style "Claude Scrum Team / Auto Mode" wordmark, drawn with
  # standard ASCII glyphs so it renders identically on every TERM.
  cat >&2 <<EOF

   ____ _                 _        ____                              _____
  / ___| | __ _ _   _  __| | ___  / ___|  ___ _ __ _   _ _ __ ___   |_   _|__  __ _ _ __ ___
 | |   | |/ _\` | | | |/ _\` |/ _ \\ \\___ \\ / __| '__| | | | '_ \` _ \\    | |/ _ \\/ _\` | '_ \` _ \\
 | |___| | (_| | |_| | (_| |  __/  ___) | (__| |  | |_| | | | | | |   | |  __/ (_| | | | | | |
  \\____|_|\\__,_|\\__,_|\\__,_|\\___| |____/ \\___|_|   \\__,_|_| |_| |_|   |_|\\___|\\__,_|_| |_| |_|
             _         _          __  __           _
            / \\  _   _| |_ ___   |  \\/  | ___   __| | ___
  _____    / _ \\| | | | __/ _ \\  | |\\/| |/ _ \\ / _\` |/ _ \\
 |_____|  / ___ \\ |_| | || (_) | | |  | | (_) | (_| |  __/
         /_/   \\_\\__,_|\\__\\___/  |_|  |_|\\___/ \\__,_|\\___|

       Ralph Loop  ·  Limits: ${MAX_ITERATIONS} iter · ${MAX_WALL_HOURS}h · ${MAX_SPRINTS} sprints

       ▸ This pane shows iteration boundaries only.
       ▸ Live PBI board · work log · PO decisions →  RIGHT PANE
         focus with  Ctrl-b o

EOF
}

# finalize <exit_code> <reason>
# Always invoked on watchdog exit (success or failure).
finalize() {
  local code="$1" reason="$2"
  # Clear our pid so a later session (e.g. an interactive `claude` opened in
  # this repo after the run) sees no live watchdog and the Stop gate behaves
  # in human mode rather than block-every-Stop. Best-effort: a crash that
  # skips finalize leaves a stale pid, but `kill -0` on the dead pid still
  # reports "not alive", so the gate degrades correctly either way.
  autonomy_atomic_write "(.watchdog_pid = null) | (.updated_at = \"$(iso_utc_now)\")" || true
  local report_path
  report_path="$(generate_morning_report "$reason" || true)"
  if [ -n "$report_path" ]; then
    printf 'watchdog: morning report → %s\n' "$report_path" >&2
  fi
  run_notify "$code" || true
  exit "$code"
}

# ---------------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------------

if [ ! -f "$AUTONOMY_FILE" ]; then
  printf 'watchdog: %s missing — run scrum-start.sh --autonomous first.\n' \
    "$AUTONOMY_FILE" >&2
  exit 3
fi
if ! jq empty "$AUTONOMY_FILE" >/dev/null 2>&1; then
  printf 'watchdog: %s is not valid JSON.\n' "$AUTONOMY_FILE" >&2
  exit 3
fi
mkdir -p "$ITER_OUT_DIR"

MAX_ITERATIONS="$(cfg_value '.autonomous.max_iterations' "$DEFAULT_MAX_ITERATIONS")"
MAX_WALL_HOURS="$(cfg_value '.autonomous.max_wall_clock_hours' "$DEFAULT_MAX_WALL_HOURS")"
MAX_SPRINTS="$(cfg_value '.autonomous.max_sprints' "$DEFAULT_MAX_SPRINTS")"
MAX_CONSECUTIVE_FAILURES="$(cfg_value '.autonomous.max_consecutive_failures' "$DEFAULT_MAX_CONSECUTIVE_FAILURES")"
PERMISSION_MODE="$(cfg_value '.autonomous.permission_mode' "$DEFAULT_PERMISSION_MODE")"
case "$PERMISSION_MODE" in
  dontAsk|bypassPermissions) ;;
  *) PERMISSION_MODE="$DEFAULT_PERMISSION_MODE" ;;
esac
FALLBACK_MODEL="$(cfg_str_or_null '.autonomous.fallback_model')"

# wall-clock seconds limit
MAX_WALL_SECS="$(awk -v h="$MAX_WALL_HOURS" 'BEGIN{printf "%d", h*3600}')"
START_EPOCH="$(now_epoch)"

print_startup_banner

printf 'watchdog: starting (max_iter=%s, max_hours=%s, max_sprints=%s, max_failures=%s)\n' \
  "$MAX_ITERATIONS" "$MAX_WALL_HOURS" "$MAX_SPRINTS" "$MAX_CONSECUTIVE_FAILURES" >&2

# Record our PID so the Stop gate can verify a live outer loop is driving this
# run (hooks/lib/autonomy.sh::autonomy_watchdog_alive). Without it the gate
# would block every Stop with no watchdog to re-launch the session — the
# "Stop storm" failure mode. Cleared to null in finalize() on clean exit.
WATCHDOG_PID="$$"
if ! autonomy_atomic_write "(.watchdog_pid = ${WATCHDOG_PID}) | (.updated_at = \"$(iso_utc_now)\")"; then
  printf 'watchdog: WARN failed to record watchdog_pid in autonomy.json.\n' >&2
fi

# Sprint budget baseline. `max_sprints` is the number of Sprints to run
# *this launch*, measured from the sprint-history length captured at
# startup — NOT a cumulative cap. A project that already has B Sprints in
# history and max_sprints=M runs until history reaches B+M. The baseline is
# captured once and persisted to autonomy.json so a resumed watchdog (same
# run) continues the original budget instead of granting a fresh M; a fresh
# scrum-start.sh --autonomous writes a baseline-less autonomy.json, so the
# next launch re-captures against the then-current history length.
SPRINT_BASELINE="$(_jq_safe "$AUTONOMY_FILE" '.sprint_baseline // empty' '')"
if [ -z "$SPRINT_BASELINE" ]; then
  SPRINT_BASELINE=0
  if [ -f "$SPRINT_HISTORY_FILE" ] && jq empty "$SPRINT_HISTORY_FILE" >/dev/null 2>&1; then
    SPRINT_BASELINE="$(jq -r '(.sprints // []) | length' "$SPRINT_HISTORY_FILE" 2>/dev/null || echo 0)"
  fi
  if ! autonomy_atomic_write \
       "(.sprint_baseline = ${SPRINT_BASELINE}) | (.updated_at = \"$(iso_utc_now)\")"; then
    printf 'watchdog: WARN failed to record sprint_baseline in autonomy.json.\n' >&2
  fi
fi
SPRINT_LIMIT=$((SPRINT_BASELINE + MAX_SPRINTS))
printf 'watchdog: sprint budget: baseline=%s + max_sprints=%s → stop at history=%s\n' \
  "$SPRINT_BASELINE" "$MAX_SPRINTS" "$SPRINT_LIMIT" >&2

# Loop-local accumulators
ITER=0
FAIL_STREAK=0
LAST_HASH="__INIT__"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while :; do
  ITER=$((ITER + 1))

  # ----- 1. Safety valves -----
  if [ "$ITER" -gt "$MAX_ITERATIONS" ]; then
    printf 'watchdog: max_iterations (%s) exceeded.\n' "$MAX_ITERATIONS" >&2
    finalize 2 "max_iterations_exceeded"
  fi

  NOW_EPOCH="$(now_epoch)"
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  if [ "$ELAPSED" -gt "$MAX_WALL_SECS" ]; then
    printf 'watchdog: max_wall_clock_hours (%s) exceeded (elapsed=%ss).\n' \
      "$MAX_WALL_HOURS" "$ELAPSED" >&2
    finalize 2 "max_wall_clock_exceeded"
  fi

  SPRINT_COUNT=0
  if [ -f "$SPRINT_HISTORY_FILE" ] && jq empty "$SPRINT_HISTORY_FILE" >/dev/null 2>&1; then
    SPRINT_COUNT="$(jq -r '(.sprints // []) | length' "$SPRINT_HISTORY_FILE" 2>/dev/null || echo 0)"
  fi
  if [ "${SPRINT_COUNT:-0}" -ge "$SPRINT_LIMIT" ]; then
    printf 'watchdog: max_sprints (%s) reached (baseline=%s, history=%s, limit=%s).\n' \
      "$MAX_SPRINTS" "$SPRINT_BASELINE" "$SPRINT_COUNT" "$SPRINT_LIMIT" >&2
    finalize 2 "max_sprints_reached"
  fi

  # ----- 2. Phase check -----
  PHASE="$(_jq_safe "$STATE_FILE" '.phase // ""' '')"
  if [ "$PHASE" = "complete" ]; then
    printf 'watchdog: phase=complete — finishing.\n' >&2
    finalize 0 "complete"
  fi

  # ----- 3. Session ID + autonomy bookkeeping -----
  SID="$(generate_uuid)"
  if ! autonomy_atomic_write \
       "(.iteration = ${ITER}) | (.lead_session_id = \"${SID}\") | (.stop_blocks = {phase: (.stop_blocks.phase // \"\"), count: 0}) | (.updated_at = \"$(iso_utc_now)\")"; then
    printf 'watchdog: failed to update autonomy.json — aborting.\n' >&2
    finalize 3 "autonomy_write_failed"
  fi

  # ----- 4. Build prompt + launch -----
  PROMPT="$(build_prompt "$PHASE")"
  ITER_STDOUT="${ITER_OUT_DIR}/iter-${ITER}.json"
  ITER_STDERR="${ITER_OUT_DIR}/iter-${ITER}.err"
  ITER_START_EPOCH="$NOW_EPOCH"

  printf 'watchdog: iteration %s (phase=%s, sid=%s)\n' "$ITER" "${PHASE:-<empty>}" "$SID" >&2

  CLAUDE_ARGS=(
    -p "$PROMPT"
    --agent scrum-master
    --session-id "$SID"
    --permission-mode "$PERMISSION_MODE"
    --output-format json
  )
  if [ -n "$FALLBACK_MODEL" ]; then
    CLAUDE_ARGS+=( --fallback-model "$FALLBACK_MODEL" )
  fi

  # Capture rc without aborting under `set -e`.
  rc=0
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    "$AUTON_CLAUDE_BIN" "${CLAUDE_ARGS[@]}" \
    >"$ITER_STDOUT" 2>"$ITER_STDERR" || rc=$?

  # ----- 5. Cost accounting -----
  if [ -s "$ITER_STDOUT" ] && jq empty "$ITER_STDOUT" >/dev/null 2>&1; then
    ITER_COST="$(jq -r '.total_cost_usd // 0' "$ITER_STDOUT" 2>/dev/null || echo 0)"
    if [ -n "$ITER_COST" ] && [ "$ITER_COST" != "null" ] && [ "$ITER_COST" != "0" ]; then
      autonomy_atomic_write \
        "(.total_cost_usd = ((.total_cost_usd // 0) + ${ITER_COST})) | (.updated_at = \"$(iso_utc_now)\")" \
        || true
    fi
  fi

  # ----- 6. Progress + rate-limit + failure judgement -----
  NEW_HASH="$(progress_hash)"

  # Rate-limit / usage-limit detection. Two independent signals:
  #   (a) the captured `claude -p` result JSON has an is_error envelope
  #       with a rate-limit / usage-limit / overload subtype or message,
  #   (b) dashboard.json has a stop_failure event since this iteration
  #       started whose detail matches the same patterns.
  # Either signal triggers a wait. We do NOT count rate-limited iterations
  # toward the iteration cap (decrement ITER before continue) so the user's
  # Sprint budget isn't consumed by waiting; runaway protection comes from
  # max_wall_clock_hours.
  RATE_LIMITED=0
  RESET_EPOCH=""
  if iter_is_rate_limit_error "$ITER_STDOUT"; then
    RATE_LIMITED=1
    RESET_EPOCH="$(extract_rate_limit_reset_epoch "$ITER_STDOUT" || true)"
  elif rate_limited_since "$ITER_START_EPOCH"; then
    RATE_LIMITED=1
  fi

  if [ "$RATE_LIMITED" = "1" ]; then
    WAIT_SECS="$DEFAULT_RATE_LIMIT_WAIT_SECS"
    if [ -n "$RESET_EPOCH" ]; then
      NOW_EPOCH2="$(now_epoch)"
      # +60s jitter beyond the advertised reset to avoid racing the server.
      WAIT_SECS=$((RESET_EPOCH - NOW_EPOCH2 + 60))
      if [ "$WAIT_SECS" -lt 60 ]; then
        WAIT_SECS=60
      fi
      if [ "$WAIT_SECS" -gt "$MAX_RATE_LIMIT_WAIT_SECS" ]; then
        WAIT_SECS="$MAX_RATE_LIMIT_WAIT_SECS"
      fi
      printf 'watchdog: rate-limit detected; sleeping %ss until reset (epoch=%s)\n' \
        "$WAIT_SECS" "$RESET_EPOCH" >&2
    else
      printf 'watchdog: rate-limit detected; no reset time parsed — sleeping %ss\n' \
        "$WAIT_SECS" >&2
    fi
    autonomy_atomic_write \
      "(.last_failure = {reason: \"rate_limit_wait\", at: \"$(iso_utc_now)\"}) | (.updated_at = \"$(iso_utc_now)\")" \
      || true
    do_sleep "$WAIT_SECS"
    LAST_HASH="$NEW_HASH"
    ITER=$((ITER - 1))
    continue
  fi

  CB_TRIPPED="$(jq -r '.circuit_breaker_tripped // empty' "$AUTONOMY_FILE" 2>/dev/null || true)"
  # Clear the breaker so the next iteration starts clean.
  if [ -n "$CB_TRIPPED" ]; then
    autonomy_atomic_write \
      "(.circuit_breaker_tripped = null) | (.updated_at = \"$(iso_utc_now)\")" || true
  fi

  PROGRESSED=0
  if [ "$NEW_HASH" != "$LAST_HASH" ] && [ "$LAST_HASH" != "__INIT__" ]; then
    PROGRESSED=1
  elif [ "$LAST_HASH" = "__INIT__" ]; then
    # First iteration — treat as progress if there's no rc failure and no CB.
    if [ "$rc" -eq 0 ] && [ -z "$CB_TRIPPED" ]; then
      PROGRESSED=1
    fi
  fi

  if [ "$PROGRESSED" = "1" ] && [ "$rc" -eq 0 ] && [ -z "$CB_TRIPPED" ]; then
    FAIL_STREAK=0
  else
    FAIL_STREAK=$((FAIL_STREAK + 1))
    REASON="no_progress"
    [ "$rc" -ne 0 ]      && REASON="claude_exit_${rc}"
    [ -n "$CB_TRIPPED" ] && REASON="circuit_breaker"
    autonomy_atomic_write \
      "(.last_failure = {reason: \"${REASON}\", at: \"$(iso_utc_now)\"}) | (.updated_at = \"$(iso_utc_now)\")" \
      || true
    printf 'watchdog: failure (%s); fail_streak=%s\n' "$REASON" "$FAIL_STREAK" >&2
  fi

  LAST_HASH="$NEW_HASH"

  if [ "$FAIL_STREAK" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    printf 'watchdog: %s consecutive failures — giving up.\n' "$FAIL_STREAK" >&2
    finalize 1 "max_consecutive_failures"
  fi
done
