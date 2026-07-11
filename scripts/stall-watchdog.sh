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
#                                        `pbi_pipeline_active` in-flight filter
#                                        in completion-gate.sh)
#   .scrum/dashboard.json mtime        — hook event activity
#   .scrum/pbi/<id>/ recursive mtime   — pipeline artifact activity
#
# Two independent stall detectors:
#   Global   — no activity anywhere (max of the signals above) for
#              idle_threshold_minutes. Catches a fully dead team.
#   Per-PBI  — a single in-flight PBI whose own activity (its
#              .scrum/pbi/<id>/ artifact tree, its worktree's last
#              commit, and dirty/untracked worktree file mtimes) is
#              older than pbi_idle_threshold_minutes, even while other
#              teammates keep the global signals fresh. Catches the
#              "one stalled conductor masked by an otherwise busy
#              team" case, which the global detector cannot see.
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
#     "pbi_idle_threshold_minutes": 15,   // default: idle_threshold_minutes
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

# now_epoch / iso_utc_now come from scripts/lib/time.sh (sourced above).

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
# Thin wrapper over the shared jq_cfg_or (scripts/lib/jq-read.sh), binding the
# config file.
read_cfg_or() {
  jq_cfg_or "$CONFIG_FILE" "$1" "$2"
}

# read_cfg_uint_or <jq_path> <default>
# Like read_cfg_or, but validates the scalar is an unsigned integer (digits
# only; "0" is accepted) and falls back to <default> otherwise — the single
# definition of the "positive-integer config fallback" idiom this file used to
# repeat inline after every read_cfg_or for a numeric setting. (jq_cfg_or in
# scripts/lib/jq-read.sh does NO type validation by contract; the shared lib
# is out of this daemon's edit scope, so the typed reader is defined here as a
# local wrapper mirroring read_cfg_or.)
read_cfg_uint_or() {
  local v
  v="$(jq_cfg_or "$CONFIG_FILE" "$1" "$2")"
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$v" ;;
  esac
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

# in_flight_snapshot — the ONE place the in-flight PBI filter lives in this
# file. Reads backlog.json once and emits one TSV line "<id>\t<status>" per
# PBI in in_progress_* (excluding in_progress_merge); the id field may be
# empty. Count, ids, and the grouped status summary are all derived from this
# single snapshot (snapshot_count / snapshot_ids / snapshot_summary) so the
# filter and the backlog read are no longer duplicated three times.
# Mirrors the `pbi_pipeline_active` in-flight filter in
# hooks/completion-gate.sh — a DIFFERENT process family. Per the documented
# no-cross-source convention between scripts/ and hooks/lib/ (see
# scripts/scrum/lib/atomic.sh / queries.sh), the two are kept in sync by hand,
# not shared; keep them in sync when changing the filter. Emits nothing on a
# missing / unparseable backlog.
in_flight_snapshot() {
  if [ ! -f "$BACKLOG_FILE" ] || ! jq empty "$BACKLOG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  jq -r '
    .items[]?
      | select(.status | startswith("in_progress_"))
      | select(.status != "in_progress_merge")
      | [(.id // ""), .status]
      | @tsv
  ' "$BACKLOG_FILE" 2>/dev/null || true
}

# snapshot_count <snapshot> — number of in-flight PBIs (every snapshot line).
snapshot_count() {
  if [ -z "$1" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$1" | grep -c .
}

# snapshot_ids <snapshot> — the non-empty PBI ids, one per line.
snapshot_ids() {
  [ -z "$1" ] && return 0
  printf '%s\n' "$1" | cut -f1 | grep -v '^$' || true
}

# snapshot_summary <snapshot> — grouped "N status" join. Statuses keep their
# in_progress_ prefix (matching the historical stall message). An empty
# snapshot yields an empty line.
snapshot_summary() {
  [ -z "$1" ] && { printf '\n'; return 0; }
  printf '%s\n' "$1" | cut -f2 | jq -Rrn '
    [inputs]
    | if length == 0 then ""
      else (group_by(.) | map("\(length) \(.[0])") | join(", "))
      end
  ' 2>/dev/null || printf '\n'
}

# pbi_activity_epoch <pbi_id> — newest activity epoch attributable to ONE
# PBI:
#   - .scrum/pbi/<id>/ recursive mtime (state.json, pipeline.log, reviews,
#     metrics — small, controlled tree)
#   - the PBI worktree's last commit time (commit-pbi.sh commits)
#   - dirty/untracked file mtimes from `git status --porcelain` in the
#     worktree (live sub-agent edits between commits), capped at 200
#     entries so a pathological worktree cannot stall the poll loop
# Emits 0 when the PBI artifact dir does not exist yet (pipeline not
# initialized) — callers must skip those rather than treat 0 as "stale
# since epoch".
pbi_activity_epoch() {
  local id="$1"
  local dir="$PBI_DIR/$id" wt="$SCRUM_DIR/worktrees/$id"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  local max m
  max="$(max_mtime_recursive "$dir")"
  if [ -d "$wt" ] && command -v git >/dev/null 2>&1; then
    m="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || true)"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -gt "$max" ] && max="$m"
    # Porcelain lines are "XY path"; rename lines ("R  old -> new") yield a
    # non-existent combined path, which mtime_of maps to 0 — harmless.
    local p
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      m="$(mtime_of "$wt/$p")"
      [ "$m" -gt "$max" ] && max="$m"
    done <<EOF
$(git -C "$wt" status --porcelain 2>/dev/null | head -n 200 | cut -c4-)
EOF
  fi
  printf '%s\n' "$max"
}

# stale_pbi_list <now_epoch> <threshold_seconds> <snapshot> — emit "id(Nm)"
# tokens, one per line, for every in-flight PBI whose per-PBI activity is
# older than the threshold. PBIs without an artifact dir are skipped (the
# global idle detector still covers a team that never started). Ids are
# derived from the shared in-flight snapshot.
stale_pbi_list() {
  local now="$1" threshold="$2" snapshot="$3" id act idle
  snapshot_ids "$snapshot" | while IFS= read -r id; do
    [ -z "$id" ] && continue
    act="$(pbi_activity_epoch "$id")"
    [ "$act" -eq 0 ] && continue
    idle=$((now - act))
    if [ "$idle" -gt "$threshold" ]; then
      printf '%s(%sm)\n' "$id" "$((idle / 60))"
    fi
  done
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
  enabled="$(read_cfg_or '.stall_watchdog.enabled' "$DEFAULT_ENABLED")"
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

  # In-flight snapshot (single backlog read) — count / ids / summary derive
  # from this one projection.
  local snapshot in_flight
  snapshot="$(in_flight_snapshot)"
  in_flight="$(snapshot_count "$snapshot")"
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

  # Decide which detector (if any) fires. Global takes precedence; when
  # global activity is fresh, look for individually stalled PBIs that the
  # rest of the team's activity would otherwise mask.
  local nudge_msg=""
  if [ "$idle_seconds" -gt "$threshold_seconds" ]; then
    local summary
    summary="$(snapshot_summary "$snapshot")"
    nudge_msg="[STALL-WATCHDOG] no activity for ${idle_threshold_min}m; in-flight: ${summary:-unknown}. Probe teammates via SendMessage/TaskGet; re-spawn only if terminated AND artifact missing."
  else
    local stale_pbis
    stale_pbis="$(stale_pbi_list "$now" $((pbi_idle_threshold_min * 60)) "$snapshot" | tr '\n' ' ')"
    # Trim the trailing space from the join.
    stale_pbis="${stale_pbis% }"
    if [ -z "$stale_pbis" ]; then
      log_msg INFO "active: idle=${idle_seconds}s threshold=${threshold_seconds}s in_flight=${in_flight}"
      return 0
    fi
    nudge_msg="[STALL-WATCHDOG] per-PBI stall: ${stale_pbis} quiet over ${pbi_idle_threshold_min}m while other team activity continues. Probe the owning Developer via SendMessage/TaskGet; re-spawn only if terminated AND artifact missing."
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
