#!/usr/bin/env bash
# scripts/stall-watchdog.sh — External teammate stall monitor.
#
# Background daemon launched by scrum-start.sh (non-autonomous mode only).
# Replaces the legacy SM-side "Stop hook block" approach: instead of forcing
# the Scrum Master to babysit teammate liveness on every turn-end (which
# burned context), this daemon watches filesystem signals from outside the
# Claude session. Its timer invokes pbi-idle.sh and exits silently while all
# observed PBIs are fresh; only stale or unknown results nudge the SM.
#
# Signals consulted:
#   scripts/scrum/pbi-idle.sh          — the single per-PBI activity reader,
#                                        over backlog, artifacts, commits, and
#                                        dirty worktree files
#
# The signal implementations live in scripts/scrum/lib/activity.sh and are
# consumed by pbi-idle.sh. This file owns only timer, cooldown, and handoff
# policy. Unknown/uninitialized activity is never converted to "fresh".
#
# Nudge transport:
#   tmux send-keys -t <sm_pane_id>     — single-line probe sent to the SM
#                                        pane. The SM is idle waiting for
#                                        the user. Used only for an anomalous
#                                        stale/unknown explorer handoff, never
#                                        for a normal fresh poll.
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
#     "idle_threshold_minutes": 30,
#     "pbi_idle_threshold_minutes": 30,   // default: idle_threshold_minutes
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
#   SCRUM_NOW_EPOCH    — pins now_epoch for deterministic comparison (shared
#                        seam in scripts/lib/time.sh). The legacy name
#                        STALL_NOW_EPOCH is still honored as an alias.
#
# Bash 3.2 compatible. shellcheck clean.

set -euo pipefail

STALL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/jq-read.sh
. "$STALL_SCRIPT_DIR/lib/jq-read.sh"
# shellcheck source=lib/time.sh
. "$STALL_SCRIPT_DIR/lib/time.sh"
# shellcheck source=scrum/lib/activity.sh
. "$STALL_SCRIPT_DIR/scrum/lib/activity.sh"

# Back-compat: honor the legacy per-daemon override name by mapping it onto
# the shared time.sh seam (explicit SCRUM_NOW_EPOCH wins when both are set).
if [ -z "${SCRUM_NOW_EPOCH:-}" ] && [ -n "${STALL_NOW_EPOCH:-}" ]; then
  SCRUM_NOW_EPOCH="$STALL_NOW_EPOCH"
fi

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
LOG_DIR="$SCRUM_DIR/logs"
LOG_FILE="$LOG_DIR/stall-watchdog.log"
STATE_FILE="$LOG_DIR/stall-watchdog.state"

DEFAULT_ENABLED="true"
# 30 minutes, not 10: healthy multi-aspect review stages measured 11-25
# minutes of zero artifact activity (Issue #95). Rationale and the full
# nudge contract: docs/contracts/agent-interfaces.md
# § External liveness nudge.
DEFAULT_IDLE_THRESHOLD_MIN=30
DEFAULT_COOLDOWN_MIN=15
DEFAULT_POLL_INTERVAL_SEC=60

TMUX_BIN="${STALL_TMUX_BIN:-tmux}"
PBI_IDLE_BIN="${STALL_PBI_IDLE_BIN:-$STALL_SCRIPT_DIR/scrum/pbi-idle.sh}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# now_epoch / iso_utc_now come from scripts/lib/time.sh (sourced above).

log_msg() {
  # log_msg <level> <message>
  local level="$1" msg="$2"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(iso_utc_now)" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# mtime_of / max_mtime_recursive / pbi_activity_epoch / in_flight_snapshot
# come from scripts/scrum/lib/activity.sh (sourced above).

# read_cfg_or <jq_path> <default>
# Thin wrapper over the shared jq_cfg_or (scripts/lib/jq-read.sh), binding the
# config file.
read_cfg_or() {
  jq_cfg_or "$CONFIG_FILE" "$1" "$2"
}

# read_cfg_uint_or <jq_path> <default>
# Thin wrapper over the shared jq_cfg_uint_or (scripts/lib/jq-read.sh),
# binding the config file — the unsigned-integer variant of read_cfg_or.
read_cfg_uint_or() {
  jq_cfg_uint_or "$CONFIG_FILE" "$1" "$2"
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

# Count, ids, and the grouped status summary all derive from the single
# in_flight_snapshot projection (activity.sh) so the filter and the backlog
# read are not duplicated per consumer.

# snapshot_count <snapshot> — number of in-flight PBIs (every snapshot line).
snapshot_count() {
  if [ -z "$1" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$1" | grep -c .
}

# send_nudge <pane> <message>
# Independent function so bats can stub tmux via a PATH shim. Returns 0 on
# success regardless of tmux exit so the loop never crashes on transient
# tmux errors.
send_nudge() {
  local pane="$1" nudge_msg="$2"
  if "$TMUX_BIN" send-keys -t "$pane" "$nudge_msg" 2>/dev/null; then
    "$TMUX_BIN" send-keys -t "$pane" Enter 2>/dev/null || true
    log_msg INFO "nudge sent to pane=$pane msg=\"$nudge_msg\""
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
  # jq's `//` treats boolean false like null, so the generic scalar helper
  # cannot distinguish an explicit disable from a missing key.
  if [ -f "$CONFIG_FILE" ] && jq -e '.stall_watchdog | has("enabled")' "$CONFIG_FILE" >/dev/null 2>&1; then
    enabled="$(jq -r '.stall_watchdog.enabled' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_ENABLED")"
  else
    enabled="$DEFAULT_ENABLED"
  fi
  case "$enabled" in
    false|0|"") log_msg INFO "stall_watchdog disabled by config"; return 99 ;;
  esac

  # read_cfg_uint_or validates the unsigned-integer fallback in one place.
  idle_threshold_min="$(read_cfg_uint_or '.stall_watchdog.idle_threshold_minutes' "$DEFAULT_IDLE_THRESHOLD_MIN")"
  cooldown_min="$(read_cfg_uint_or '.stall_watchdog.cooldown_minutes' "$DEFAULT_COOLDOWN_MIN")"

  # Per-PBI threshold defaults to the global idle threshold — one knob
  # unless the operator wants different sensitivities.
  local pbi_idle_threshold_min
  pbi_idle_threshold_min="$(read_cfg_uint_or '.stall_watchdog.pbi_idle_threshold_minutes' "$idle_threshold_min")"

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

  # A missing or malformed backlog is unknown, never an empty team. Since the
  # only safe handoff transport for this daemon is the configured tmux pane,
  # request one bounded Explorer there instead of claiming no work is active.
  local backlog_unknown=0
  if [ ! -f "$BACKLOG_FILE" ] || ! jq -e '(.items | type) == "array"' "$BACKLOG_FILE" >/dev/null 2>&1; then
    backlog_unknown=1
  fi

  # In-flight snapshot (single valid backlog read) — count / ids / summary
  # derive from this one projection.
  local snapshot in_flight
  if [ "$backlog_unknown" = "1" ]; then
    snapshot=""
  else
    snapshot="$(in_flight_snapshot "$BACKLOG_FILE")"
  fi
  in_flight="$(snapshot_count "$snapshot")"
  if [ "$backlog_unknown" = "0" ] && [ "${in_flight:-0}" -eq 0 ]; then
    log_msg INFO "no in-flight PBIs; nothing to monitor"
    return 0
  fi

  # The timer's only normal path is the read-only pbi-idle reporter. A fresh
  # report exits here without sending tmux input, so the periodic check does
  # not wake an LLM merely to confirm that work is healthy. Stale and unknown
  # (never initialized or unreadable) results alone request one bounded,
  # read-only explorer investigation from the SM.
  local now cooldown_seconds idle_report idle_rc stale_ids unknown_ids
  now="$(now_epoch)"
  cooldown_seconds=$((cooldown_min * 60))
  local nudge_msg=""
  idle_rc=0
  if [ "$backlog_unknown" = "1" ]; then
    idle_rc=65
    idle_report=""
  else
    idle_report="$(cd "$PROJECT_DIR" && SCRUM_NOW_EPOCH="$now" "$PBI_IDLE_BIN" --threshold-minutes "$pbi_idle_threshold_min" 2>&1)" || idle_rc=$?
  fi
  if [ "$backlog_unknown" = "1" ]; then
    nudge_msg="[STALL-WATCHDOG] PBI liveness is unknown because backlog.json is missing, malformed, or lacks an items array. Spawn one bounded read-only explorer to inspect backlog and per-PBI artifacts, report evidence to the SM, then exit. Do not infer that there are no in-flight PBIs and do not wake or respawn a Developer from this timer alone."
  elif [ "$idle_rc" -ne 0 ]; then
    nudge_msg="[STALL-WATCHDOG] PBI liveness is unknown because pbi-idle.sh exited ${idle_rc}. Spawn one bounded read-only explorer to inspect backlog and per-PBI artifacts, report evidence to the SM, then exit. Do not wake or respawn a Developer from this timer alone."
  else
    stale_ids="$(printf '%s\n' "$idle_report" | awk -F '\t' '!/^#/ && $6 == "stale" {print $1}' | tr '\n' ' ')"
    unknown_ids="$(printf '%s\n' "$idle_report" | awk -F '\t' '!/^#/ && $6 == "uninitialized" {print $1}' | tr '\n' ' ')"
    stale_ids="${stale_ids% }"
    unknown_ids="${unknown_ids% }"
    if [ -z "$stale_ids" ] && [ -z "$unknown_ids" ]; then
      log_msg INFO "pbi-idle fresh; in_flight=${in_flight}; normal exit without model wakeup"
      return 0
    fi
    nudge_msg="[STALL-WATCHDOG] bounded investigation requested; stale PBIs: ${stale_ids:-none}; unknown/uninitialized PBIs: ${unknown_ids:-none}. Spawn one bounded read-only explorer to inspect activity artifacts and teammate evidence, report findings to the SM, then exit. Do not respawn a Developer unless the SM separately confirms termination and missing expected artifacts."
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
  send_nudge "$pane" "$nudge_msg"
  write_last_nudge_epoch "$now"
  return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# Read poll interval once at startup — config edits during a run pick up next
# loop iteration via the next read_cfg_or call inside run_once.
POLL_INTERVAL_SEC="$(read_cfg_uint_or '.stall_watchdog.poll_interval_seconds' "$DEFAULT_POLL_INTERVAL_SEC")"

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
