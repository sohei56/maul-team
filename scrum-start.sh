#!/usr/bin/env bash
# scrum-start.sh — Entry point for the AI-Powered Scrum Team
#
# Usage (interactive / human-PO mode):
#   sh scrum-start.sh
#
# Usage (autonomous-PO mode — Ralph Loop, no human at the keyboard):
#   sh scrum-start.sh --autonomous [--brief docs/product/brief.md] \
#                     [--max-sprints N] [--max-hours H] \
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
#   --bypass-permissions    Sets autonomous.permission_mode = bypassPermissions
#                           (default: dontAsk).
#   --no-attach             Skip `tmux attach-session` after launching; useful
#                           when starting overnight runs.
#
# Prerequisites:
#   - Claude Code CLI on PATH
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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Parse CLI flags (Bash 3.2 compatible; no getopts) ----------------------
AUTONOMOUS=0
BRIEF_FILE=""
OPT_MAX_SPRINTS=""
OPT_MAX_HOURS=""
BYPASS_PERMS=0
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
    --bypass-permissions) BYPASS_PERMS=1; shift ;;
    --no-attach)          NO_ATTACH=1; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0 ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2 ;;
  esac
done

# --- Validate prerequisites ---

# shellcheck source=scripts/lib/check-python.sh
. "$SCRIPT_DIR/scripts/lib/check-python.sh"
check_claude_cli
check_python_prereqs

# --- Run setup (copies agents, skills, hooks, configures settings) ---
sh "$SCRIPT_DIR/scripts/setup-user.sh"

# --- Detect new vs resume and set initial prompt ---
IS_NEW_PROJECT=0
if [ -f ".scrum/state.json" ]; then
  echo ""
  echo "Existing project detected — resuming from saved state."

  # Migrate legacy .scrum/*.json (pre-SSOT layout) idempotently before launch.
  # No-op if files are already canonical. Keeps .legacy.bak alongside changes.
  if [ -x "$SCRIPT_DIR/scripts/scrum/migrate-legacy.sh" ]; then
    sh "$SCRIPT_DIR/scripts/scrum/migrate-legacy.sh" || \
      echo "Warning: migrate-legacy.sh reported issues (continuing)" >&2
  fi

  phase="$(jq -r '.phase // "unknown"' .scrum/state.json)"
  echo "  Current phase: $phase"
  initial_prompt="Read .scrum/state.json, .scrum/sprint.json, and .scrum/backlog.json. Reconcile PBI statuses in backlog.json against actual project state — check if implementation files exist for each in-progress PBI and update statuses accordingly (e.g., mark PBIs as done if their code is complete, or keep as in_progress if work remains). Report where we left off, then continue the workflow from the current phase."
else
  IS_NEW_PROJECT=1
  echo ""
  echo "New project — starting fresh."
  mkdir -p .scrum/reviews
  # Bootstrap .scrum/state.json via the deployed wrapper so the SM's first
  # update-state-phase call has a file to mutate. setup-user.sh above has
  # already copied scripts/scrum/*.sh to .scrum/scripts/.
  sh .scrum/scripts/init-state.sh
  initial_prompt="Introduce yourself and begin the Requirements Sprint. Greet the user, explain the Scrum workflow briefly, then start eliciting requirements."
fi

# --- Autonomous-PO mode preparation ----------------------------------------
# Done before tmux/claude launch so the watchdog finds .scrum/config.json
# and .scrum/autonomy.json in place. Non-autonomous runs hit none of this.

if [ "$AUTONOMOUS" = "1" ]; then
  # New-project bootstrap requires a brief. Use the detection variable
  # captured above — init-state.sh has already created .scrum/state.json
  # in the new-project branch, so re-testing file existence here would
  # silently let an unbriefed autonomous run through.
  if [ "$IS_NEW_PROJECT" = "1" ] && [ -z "$BRIEF_FILE" ]; then
    echo "Error: --autonomous on a new project requires --brief <file>." >&2
    echo "  Provide a product brief that the autonomous PO can use to drive" >&2
    echo "  the Requirements Sprint without a human in the loop." >&2
    exit 2
  fi

  # Copy brief into the canonical location (do not overwrite if present).
  if [ -n "$BRIEF_FILE" ]; then
    if [ ! -f "$BRIEF_FILE" ]; then
      echo "Error: brief file not found: $BRIEF_FILE" >&2
      exit 2
    fi
    mkdir -p docs/product
    if [ -f "docs/product/brief.md" ]; then
      echo "Warning: docs/product/brief.md already exists — keeping existing copy." >&2
    else
      cp "$BRIEF_FILE" "docs/product/brief.md"
      echo "  Copied brief to docs/product/brief.md"
    fi
  fi

  # Merge autonomous config into .scrum/config.json.
  mkdir -p .scrum
  CONFIG_FILE=".scrum/config.json"
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '{}\n' > "$CONFIG_FILE"
  fi

  # Resolve permission_mode.
  if [ "$BYPASS_PERMS" = "1" ]; then
    PERM_MODE="bypassPermissions"
  else
    PERM_MODE="dontAsk"
  fi

  # Defaults match .scrum-config.example.json. Overrides applied last.
  TMP_CFG="${CONFIG_FILE}.tmp.$$.${RANDOM}"
  jq --arg perm "$PERM_MODE" '
    .po_mode = "agent"
    | .autonomous = (
        (.autonomous // {})
        + {
            max_iterations:            (.autonomous.max_iterations            // 50),
            max_wall_clock_hours:      (.autonomous.max_wall_clock_hours      // 8),
            max_sprints:               (.autonomous.max_sprints               // 5),
            max_consecutive_failures:  (.autonomous.max_consecutive_failures  // 3),
            stop_block_budget_per_phase: (.autonomous.stop_block_budget_per_phase // 8),
            permission_mode:           $perm,
            notify_command:            (.autonomous.notify_command            // null),
            fallback_model:            (.autonomous.fallback_model            // null)
          }
      )
  ' "$CONFIG_FILE" > "$TMP_CFG"
  mv "$TMP_CFG" "$CONFIG_FILE"

  # Apply --max-sprints / --max-hours overrides.
  if [ -n "$OPT_MAX_SPRINTS" ]; then
    TMP_CFG="${CONFIG_FILE}.tmp.$$.${RANDOM}"
    jq --argjson v "$OPT_MAX_SPRINTS" '.autonomous.max_sprints = $v' \
      "$CONFIG_FILE" > "$TMP_CFG"
    mv "$TMP_CFG" "$CONFIG_FILE"
  fi
  if [ -n "$OPT_MAX_HOURS" ]; then
    TMP_CFG="${CONFIG_FILE}.tmp.$$.${RANDOM}"
    jq --argjson v "$OPT_MAX_HOURS" '.autonomous.max_wall_clock_hours = $v' \
      "$CONFIG_FILE" > "$TMP_CFG"
    mv "$TMP_CFG" "$CONFIG_FILE"
  fi

  # Initialise .scrum/autonomy.json. Bash 3.2-compatible UUID generation.
  if command -v uuidgen >/dev/null 2>&1; then
    RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
fi

# --- Launch ---
echo ""

# Build the autonomous launch command (used by both tmux and no-tmux branches).
WATCHDOG_CMD="$SCRIPT_DIR/scripts/autonomous/watchdog.sh"

if command -v tmux >/dev/null 2>&1; then
  # tmux available — create the session, optionally with a split dashboard
  #
  # Session name is derived from the project directory so that concurrent
  # scrum-start.sh runs in *different* projects coexist on a single tmux
  # server. The hash disambiguates projects that share a basename. A run
  # inside the *same* project refuses to clobber the existing session
  # below — the user must close or attach explicitly, since silently
  # killing it has previously destroyed the predecessor's running Claude
  # session without warning.
  if command -v shasum >/dev/null 2>&1; then
    pwd_hash="$(printf '%s' "$PWD" | shasum | cut -c1-8)"
  elif command -v sha1sum >/dev/null 2>&1; then
    pwd_hash="$(printf '%s' "$PWD" | sha1sum | cut -c1-8)"
  else
    pwd_hash="$(printf '%s' "$PWD" | cksum | awk '{print $1}')"
  fi
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

  if [ "$term_cols" -ge "$min_split_cols" ]; then
    echo "Launching Scrum team with tmux dashboard..."
    if [ "$AUTONOMOUS" = "1" ]; then
      echo "  Main pane: Autonomous-PO watchdog (Ralph Loop)"
    else
      echo "  Main pane: Claude Code (Scrum Master)"
    fi
    echo "  Side pane: TUI Dashboard"
  else
    echo "Launching Scrum team in tmux..."
    if [ "$AUTONOMOUS" = "1" ]; then
      echo "  Main pane: Autonomous-PO watchdog (Ralph Loop)"
    else
      echo "  Main pane: Claude Code (Scrum Master)"
    fi
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
  RUNTIME_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    tmux send-keys -t "$session_name" \
      "${WATCHDOG_CMD}; echo; echo 'Watchdog exited.  Press Enter to close.'; read -r; tmux kill-session -t ${session_name}" C-m
  else
    # Main pane: Claude Code with Scrum Master agent (Agent Teams enabled
    # process-scoped). --teammate-mode in-process forces Agent Teams to use
    # in-process mode for teammates (Shift+Down to cycle) instead of creating
    # split panes that would overwrite the dashboard pane. The positional
    # argument starts an interactive session with an initial prompt (unlike
    # -p which exits). When Claude exits, the tmux session is killed
    # automatically.
    tmux send-keys -t "$session_name" \
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --agent scrum-master --teammate-mode in-process '${initial_prompt}'; tmux kill-session -t ${session_name}" C-m

    # External stall watchdog (non-autonomous mode only). Replaces the
    # legacy SM-side Stop-hook block-loop. Detached so it survives this
    # shell. Autonomous mode skips this because the Ralph Loop watchdog
    # already owns liveness/safety.
    STALL_WATCHDOG_SCRIPT="$SCRIPT_DIR/scripts/stall-watchdog.sh"
    if [ -x "$STALL_WATCHDOG_SCRIPT" ]; then
      nohup "$STALL_WATCHDOG_SCRIPT" "$PWD" >/dev/null 2>&1 &
      STALL_WATCHDOG_PID=$!
      # Update runtime.json with the pid (best-effort; failure not fatal).
      RUNTIME_TMP=".scrum/runtime.json.tmp.$$.${RANDOM}"
      if jq --argjson pid "$STALL_WATCHDOG_PID" \
           '.stall_watchdog_pid = $pid' \
           .scrum/runtime.json > "$RUNTIME_TMP" 2>/dev/null; then
        mv "$RUNTIME_TMP" .scrum/runtime.json
      else
        rm -f "$RUNTIME_TMP"
      fi
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
    echo "Launching autonomous-PO watchdog (no tmux fallback)..."
    "$WATCHDOG_CMD"
  else
    echo "Launching Claude Code with Scrum Master agent..."
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --agent scrum-master "$initial_prompt"
  fi
fi
