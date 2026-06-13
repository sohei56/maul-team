#!/usr/bin/env bash
# scripts/stall-watchdog.sh — External teammate stall monitor.
#
# Background daemon launched by scrum-start.sh (non-autonomous mode only).
# Replaces the legacy SM-side "Stop hook block" approach: instead of forcing
# the Scrum Master to babysit teammate liveness on every turn-end (which
# burned context), this daemon watches filesystem signals from outside the
# Claude session and nudges the SM via tmux only when no activity has been
# observed for a configurable threshold.
#
# Signals consulted:
#   .scrum/backlog.json                — in-flight PBI count (status =
#                                        in_progress_* but NOT
#                                        in_progress_merge; matches the
#                                        completion-gate.sh:348-363 filter)
#   .scrum/dashboard.json mtime        — hook event activity
#   .scrum/pbi/<id>/ recursive mtime   — pipeline artifact activity
#
# Nudge transport:
#   tmux send-keys -t <sm_pane_id>     — single-line probe sent to the SM
#                                        pane. The SM is idle waiting for
#                                        the user, so the keystroke reliably
#                                        wakes it.
#
# Usage:
#   scripts/stall-watchdog.sh <project_dir> [--once]
#
#   <project_dir>   Project root containing .scrum/.
#   --once          Run exactly one iteration of the main loop then exit.
#                   Used by bats tests to drive each scenario deterministically.
#
# Config (.scrum/config.json -> .stall_watchdog):
#   {
#     "enabled": true,
#     "idle_threshold_minutes": 15,
#     "cooldown_minutes": 15,
#     "poll_interval_seconds": 60
#   }
#
# State / logs:
#   .scrum/logs/stall-watchdog.log     — append-only event log
#   .scrum/logs/stall-watchdog.state   — single line: last_nudge_epoch
#
# Test hooks (env vars; harmless in production):
#   STALL_TMUX_BIN     — tmux binary to use (default `tmux`). Tests stub it
#                        via a PATH-shimmed script.
#   STALL_NOW_EPOCH    — override "now" for deterministic comparison.
#
# Bash 3.2 compatible. shellcheck clean.

set -euo pipefail

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

PROJECT_DIR=""
ONCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0 ;;
    --*)
      printf 'stall-watchdog: unknown flag: %s\n' "$1" >&2
      exit 2 ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        printf 'stall-watchdog: unexpected positional arg: %s\n' "$1" >&2
        exit 2
      fi
      shift ;;
  esac
done

if [ -z "$PROJECT_DIR" ]; then
  printf 'stall-watchdog: project_dir required.\nUsage: %s <project_dir> [--once]\n' "$0" >&2
  exit 2
fi

if [ ! -d "$PROJECT_DIR" ]; then
  printf 'stall-watchdog: project_dir not a directory: %s\n' "$PROJECT_DIR" >&2
  exit 2
fi

# Resolve to absolute path; the daemon may outlive the launching shell's cwd.
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRUM_DIR="$PROJECT_DIR/.scrum"
CONFIG_FILE="$SCRUM_DIR/config.json"
RUNTIME_FILE="$SCRUM_DIR/runtime.json"
BACKLOG_FILE="$SCRUM_DIR/backlog.json"
DASHBOARD_FILE="$SCRUM_DIR/dashboard.json"
PBI_DIR="$SCRUM_DIR/pbi"
LOG_DIR="$SCRUM_DIR/logs"
LOG_FILE="$LOG_DIR/stall-watchdog.log"
STATE_FILE="$LOG_DIR/stall-watchdog.state"

DEFAULT_ENABLED="true"
DEFAULT_IDLE_THRESHOLD_MIN=15
DEFAULT_COOLDOWN_MIN=15
DEFAULT_POLL_INTERVAL_SEC=60

TMUX_BIN="${STALL_TMUX_BIN:-tmux}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

now_epoch() {
  if [ -n "${STALL_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$STALL_NOW_EPOCH"
  else
    date +%s
  fi
}

iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

log_msg() {
  # log_msg <level> <message>
  local level="$1" msg="$2"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(iso_utc_now)" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# mtime_of <path> — emit epoch seconds for a file/dir mtime, portable across
# macOS (BSD stat) and Linux (GNU stat). Emits 0 if the path does not exist.
# GNU stat treats `-f %m` as "filesystem status of a file named %m" and can
# emit multi-line garbage with a nonzero exit, so each candidate output is
# validated as a pure integer before use.
mtime_of() {
  local p="$1" m
  [ -e "$p" ] || { printf '0\n'; return 0; }
  m="$(stat -f %m "$p" 2>/dev/null || true)"
  case "$m" in
    ''|*[!0-9]*) m="$(stat -c %Y "$p" 2>/dev/null || true)" ;;
  esac
  case "$m" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$m" ;;
  esac
}

# max_mtime_recursive <dir> — emit epoch of the newest mtime found anywhere
# under <dir> (inclusive). Walks files and directories so a newly-created
# subdir without files yet still counts as activity. Emits 0 on missing dir.
max_mtime_recursive() {
  local dir="$1"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  local max=0 m
  # First the dir itself
  m="$(mtime_of "$dir")"
  [ "$m" -gt "$max" ] && max="$m"
  # find -print0 not portable to bare Bash 3.2 read; the file names we walk
  # are .scrum/pbi/* — controlled internal IDs without whitespace.
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    m="$(mtime_of "$p")"
    [ "$m" -gt "$max" ] && max="$m"
  done <<EOF
$(find "$dir" -mindepth 1 2>/dev/null)
EOF
  printf '%s\n' "$max"
}

# read_cfg_or <jq_path> <default>
read_cfg_or() {
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

# last_nudge_epoch — read from STATE_FILE or 0.
last_nudge_epoch() {
  if [ -f "$STATE_FILE" ]; then
    local v
    v="$(head -n1 "$STATE_FILE" 2>/dev/null | tr -d ' \t\r\n')"
    case "$v" in
      ''|*[!0-9]*) printf '0\n' ;;
      *)           printf '%s\n' "$v" ;;
    esac
  else
    printf '0\n'
  fi
}

# write_last_nudge_epoch <epoch>
write_last_nudge_epoch() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s\n' "$1" > "$STATE_FILE"
}

# in_flight_count — number of PBIs in in_progress_* (excluding in_progress_merge).
# Mirrors hooks/completion-gate.sh:348-363 so the two stay in sync.
in_flight_count() {
  if [ ! -f "$BACKLOG_FILE" ]; then
    printf '0\n'
    return 0
  fi
  if ! jq empty "$BACKLOG_FILE" >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi
  jq -r '
    [.items[]?
      | select(.status | startswith("in_progress_"))
      | select(.status != "in_progress_merge")]
    | length
  ' "$BACKLOG_FILE" 2>/dev/null || printf '0\n'
}

# in_flight_summary — same filter, but grouped "N status" join.
in_flight_summary() {
  if [ ! -f "$BACKLOG_FILE" ] || ! jq empty "$BACKLOG_FILE" >/dev/null 2>&1; then
    printf '\n'
    return 0
  fi
  jq -r '
    [.items[]? | .status
      | select(startswith("in_progress_"))
      | select(. != "in_progress_merge")]
    | group_by(.)
    | map("\(length) \(.[0])")
    | join(", ")
  ' "$BACKLOG_FILE" 2>/dev/null || printf '\n'
}

# send_nudge <pane> <idle_minutes> <summary>
# Independent function so bats can stub tmux via a PATH shim. Returns 0 on
# success regardless of tmux exit so the loop never crashes on transient
# tmux errors.
send_nudge() {
  local pane="$1" idle_min="$2" summary="$3"
  local nudge_msg
  nudge_msg="[STALL-WATCHDOG] no activity for ${idle_min}m; in-flight: ${summary:-unknown}. Probe teammates via SendMessage/TaskGet; re-spawn only if terminated AND artifact missing."
  if "$TMUX_BIN" send-keys -t "$pane" "$nudge_msg" 2>/dev/null; then
    "$TMUX_BIN" send-keys -t "$pane" Enter 2>/dev/null || true
    log_msg INFO "nudge sent to pane=$pane idle_min=$idle_min summary=\"$summary\""
    return 0
  fi
  log_msg WARN "tmux send-keys failed for pane=$pane (continuing)"
  return 0
}

# ---------------------------------------------------------------------------
# Main iteration — exposed as a function so --once and the loop share code.
# Returns 0 on normal completion, non-zero on "team is gone, stop the
# daemon" conditions.
# ---------------------------------------------------------------------------

run_once() {
  # Config check
  local enabled idle_threshold_min cooldown_min
  enabled="$(read_cfg_or '.stall_watchdog.enabled' "$DEFAULT_ENABLED")"
  case "$enabled" in
    false|0|"") log_msg INFO "stall_watchdog disabled by config"; return 99 ;;
  esac

  idle_threshold_min="$(read_cfg_or '.stall_watchdog.idle_threshold_minutes' "$DEFAULT_IDLE_THRESHOLD_MIN")"
  cooldown_min="$(read_cfg_or '.stall_watchdog.cooldown_minutes' "$DEFAULT_COOLDOWN_MIN")"

  # Validate numerics — fall back to default if not a positive integer.
  case "$idle_threshold_min" in
    ''|*[!0-9]*) idle_threshold_min="$DEFAULT_IDLE_THRESHOLD_MIN" ;;
  esac
  case "$cooldown_min" in
    ''|*[!0-9]*) cooldown_min="$DEFAULT_COOLDOWN_MIN" ;;
  esac

  # Runtime read
  if [ ! -f "$RUNTIME_FILE" ]; then
    log_msg WARN "runtime.json missing at $RUNTIME_FILE (team not started?)"
    return 0
  fi
  if ! jq empty "$RUNTIME_FILE" >/dev/null 2>&1; then
    log_msg WARN "runtime.json is not valid JSON"
    return 0
  fi

  local session pane
  session="$(jq -r '.tmux_session // empty' "$RUNTIME_FILE" 2>/dev/null || true)"
  pane="$(jq -r '.sm_pane_id // empty' "$RUNTIME_FILE" 2>/dev/null || true)"
  if [ -z "$session" ] || [ -z "$pane" ]; then
    log_msg WARN "runtime.json missing tmux_session or sm_pane_id"
    return 0
  fi

  # tmux session liveness — exit if gone (team ended).
  if ! "$TMUX_BIN" has-session -t "=${session}" 2>/dev/null; then
    log_msg INFO "tmux session $session no longer exists — exiting"
    return 98
  fi

  # In-flight count
  local in_flight
  in_flight="$(in_flight_count)"
  if [ "${in_flight:-0}" -eq 0 ]; then
    log_msg INFO "no in-flight PBIs; nothing to monitor"
    return 0
  fi

  # Activity mtime
  local dash_mtime pbi_mtime last_activity
  dash_mtime="$(mtime_of "$DASHBOARD_FILE")"
  pbi_mtime="$(max_mtime_recursive "$PBI_DIR")"
  if [ "$dash_mtime" -gt "$pbi_mtime" ]; then
    last_activity="$dash_mtime"
  else
    last_activity="$pbi_mtime"
  fi

  local now idle_seconds threshold_seconds cooldown_seconds
  now="$(now_epoch)"
  idle_seconds=$((now - last_activity))
  threshold_seconds=$((idle_threshold_min * 60))
  cooldown_seconds=$((cooldown_min * 60))

  if [ "$idle_seconds" -le "$threshold_seconds" ]; then
    log_msg INFO "active: idle=${idle_seconds}s threshold=${threshold_seconds}s in_flight=${in_flight}"
    return 0
  fi

  # Cooldown check
  local last_nudge since_last_nudge
  last_nudge="$(last_nudge_epoch)"
  since_last_nudge=$((now - last_nudge))
  if [ "$last_nudge" -gt 0 ] && [ "$since_last_nudge" -le "$cooldown_seconds" ]; then
    log_msg INFO "stall detected but inside cooldown (since_last=${since_last_nudge}s cooldown=${cooldown_seconds}s)"
    return 0
  fi

  # Nudge
  local summary
  summary="$(in_flight_summary)"
  send_nudge "$pane" "$idle_threshold_min" "$summary"
  write_last_nudge_epoch "$now"
  return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# Read poll interval once at startup — config edits during a run pick up next
# loop iteration via the next read_cfg_or call inside run_once.
POLL_INTERVAL_SEC="$(read_cfg_or '.stall_watchdog.poll_interval_seconds' "$DEFAULT_POLL_INTERVAL_SEC")"
case "$POLL_INTERVAL_SEC" in
  ''|*[!0-9]*) POLL_INTERVAL_SEC="$DEFAULT_POLL_INTERVAL_SEC" ;;
esac

mkdir -p "$LOG_DIR" 2>/dev/null || true
log_msg INFO "starting stall-watchdog (project=$PROJECT_DIR poll=${POLL_INTERVAL_SEC}s once=${ONCE})"

if [ "$ONCE" = "1" ]; then
  rc=0
  run_once || rc=$?
  case "$rc" in
    0|98|99) exit 0 ;;
    *)       exit "$rc" ;;
  esac
fi

while :; do
  rc=0
  run_once || rc=$?
  case "$rc" in
    0)  : ;;
    98) log_msg INFO "exiting (tmux session gone)"; exit 0 ;;
    99) log_msg INFO "exiting (disabled in config)"; exit 0 ;;
    *)  log_msg WARN "run_once returned $rc — continuing" ;;
  esac
  sleep "$POLL_INTERVAL_SEC"
done
