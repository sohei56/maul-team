#!/usr/bin/env bash
# autonomy.sh — Shared helpers for hooks operating under autonomous-PO mode.
#
# This library is sourced by hooks (Stop loop, dashboard, watchdog driver)
# to read/update .scrum/autonomy.json and probe .scrum/config.json.
#
# Design principles:
#   - Fail-open: a missing file, malformed JSON, or unreadable counter must
#     never crash the hook. Returning the safe default (autonomy disabled,
#     not lead, counter 0) is always preferred over `exit 1`.
#   - No agent-side writes: hooks/lib/autonomy.sh writes through tmp + mv on
#     .scrum/autonomy.json. This file is exempted from the scrum-state-guard
#     for the hook context (separate writer ID); user/agent direct edits via
#     Write/Edit are still blocked. The wrapper used by hooks is intentionally
#     thin (no schema validation per call) because the runtime hot-path is
#     latency-sensitive; the schema is enforced by the watchdog on rotation.
#   - Bash 3.2 compatible: no associative arrays, no namerefs.

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_AUTONOMY_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_AUTONOMY_SH_LOADED=1

AUTONOMY_FILE=".scrum/autonomy.json"
SCRUM_CONFIG_FILE=".scrum/config.json"

# ISO-8601 UTC timestamp. Mirrors hooks/lib/validate.sh::get_timestamp; we
# duplicate here so this lib stays sourceable without validate.sh.
_autonomy_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

# autonomy_enabled
# Returns 0 if po_mode == "agent" AND .scrum/autonomy.json exists.
# Returns 1 otherwise (incl. missing config, missing autonomy file, bad JSON).
autonomy_enabled() {
  [ -f "$SCRUM_CONFIG_FILE" ] || return 1
  [ -f "$AUTONOMY_FILE" ]      || return 1
  local mode
  mode="$(jq -r '.po_mode // "human"' "$SCRUM_CONFIG_FILE" 2>/dev/null || echo "human")"
  [ "$mode" = "agent" ] || return 1
  return 0
}

# autonomy_watchdog_alive
# Returns 0 iff autonomy.json records a watchdog_pid that maps to a live
# process. Fail-closed: a missing file, an absent/null/non-numeric pid, or a
# pid that is not currently running all return 1 (no live watchdog). The
# watchdog records its pid at startup and clears it (null) on clean exit, so
# "alive" means an outer loop is genuinely driving the Stop iterations.
autonomy_watchdog_alive() {
  [ -f "$AUTONOMY_FILE" ] || return 1
  local pid
  pid="$(jq -r '.watchdog_pid // empty' "$AUTONOMY_FILE" 2>/dev/null || echo "")"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# autonomy_loop_active
# True iff autonomous-PO mode is enabled AND a live watchdog is driving the
# outer loop. The Stop gate uses THIS (not autonomy_enabled alone) to decide
# whether to apply block-every-Stop semantics. Rationale: the block-every-Stop
# contract exists solely to hand control back to the watchdog's inner loop;
# with no live watchdog, blocking would storm a session nothing will resume,
# so the gate must degrade to human-mode behaviour.
autonomy_loop_active() {
  autonomy_enabled || return 1
  autonomy_watchdog_alive || return 1
  return 0
}

# is_lead_session <session_id>
# Returns 0 iff autonomy.json's lead_session_id equals the given session id.
# Fail-open: missing file or null lead → return 1.
is_lead_session() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  [ -f "$AUTONOMY_FILE" ] || return 1
  local lead
  lead="$(jq -r '.lead_session_id // ""' "$AUTONOMY_FILE" 2>/dev/null || echo "")"
  [ -n "$lead" ] || return 1
  [ "$lead" = "$sid" ] || return 1
  return 0
}

# _autonomy_jq_write [-t <ts>] <jq_filter> [jq_arg...]
# File-local atomic-update helper for AUTONOMY_FILE: validates the file's
# JSON, applies <jq_filter> (with any extra jq args such as --arg pairs),
# stamps `.updated_at = $now`, and writes through tmp+mv. The `$now`
# binding defaults to _autonomy_now(); pass `-t <ts>` to stamp with a
# caller-supplied timestamp instead (an empty <ts> falls back to the
# default). Fail-open: returns 1 (never crashes) on a missing file,
# unparseable JSON, or jq failure — the tmp file is removed and
# AUTONOMY_FILE is left untouched. Lives IN this file (not validate.sh's
# json_update_atomic) because this lib must stay standalone-sourceable.
# Mirrored by scripts/autonomous/watchdog.sh::autonomy_atomic_write — a
# DIFFERENT process family kept in sync by hand, not shared, per the
# no-cross-source convention between scripts/ and hooks/lib/.
_autonomy_jq_write() {
  local now=""
  if [ "${1:-}" = "-t" ]; then
    now="${2:-}"
    shift 2
  fi
  local filter="${1:-}"
  shift
  [ -f "$AUTONOMY_FILE" ] || return 1
  jq empty "$AUTONOMY_FILE" >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(_autonomy_now)"
  local tmp
  tmp="${AUTONOMY_FILE}.tmp.$$.${RANDOM}"
  if ! jq --arg now "$now" "$@" \
    "${filter} | .updated_at = \$now" \
    "$AUTONOMY_FILE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$AUTONOMY_FILE"
  return 0
}

# bump_stop_block_counter <phase>
# Increments stop_blocks.count when stop_blocks.phase matches <phase>; resets
# to 1 with the new phase otherwise. Atomic update via tmp+mv. Echoes the new
# count on stdout. Fail-open: a missing or unparseable autonomy file echoes 0
# and returns 1 (caller can treat 0 as "not in autonomy mode").
bump_stop_block_counter() {
  local new_phase="${1:-}"
  # If the recorded phase matches new_phase: count += 1. Otherwise reset count
  # to 1 and switch phase. updated_at is bumped either way.
  # shellcheck disable=SC2016  # $phase/$now are jq variables, not shell expansion.
  if [ -z "$new_phase" ] || ! _autonomy_jq_write '
    .stop_blocks = (
      if (.stop_blocks.phase // "") == $phase then
        {phase: $phase, count: (((.stop_blocks.count // 0) + 1))}
      else
        {phase: $phase, count: 1}
      end
    )
  ' --arg phase "$new_phase"; then
    printf '0\n'
    return 1
  fi
  jq -r '.stop_blocks.count' "$AUTONOMY_FILE" 2>/dev/null || printf '0\n'
}

# record_circuit_breaker <phase>
# Marks .circuit_breaker_tripped = {phase, at: now}. Fail-open: returns 1 on
# unparseable autonomy file but does not crash.
record_circuit_breaker() {
  local phase="${1:-}"
  [ -n "$phase" ] || return 1
  # shellcheck disable=SC2016  # $phase/$now are jq variables, not shell expansion.
  _autonomy_jq_write \
    '.circuit_breaker_tripped = {phase: $phase, at: $now}' \
    --arg phase "$phase"
}

# autonomy_record_failure <reason> [ts]
# Records .last_failure = {reason, at} (and bumps .updated_at) on
# .scrum/autonomy.json so the watchdog can read the last failure and decide
# whether to retry / abort the outer loop. Fail-open: a missing or unparseable
# autonomy file returns 1 without crashing. Uses the file-local
# _autonomy_jq_write helper (this lib is sourced standalone, without
# hooks/lib/validate.sh, so it cannot rely on json_update_atomic).
# When <ts> is omitted, _autonomy_now() is used.
autonomy_record_failure() {
  local reason="${1:-}"
  local ts="${2:-}"
  # -t "$ts" stamps both .last_failure.at and .updated_at with <ts>;
  # an empty ts falls back to _autonomy_now() inside the helper.
  # shellcheck disable=SC2016  # $reason/$now are jq variables, not shell expansion.
  _autonomy_jq_write -t "$ts" \
    '.last_failure = {reason: $reason, at: $now}' \
    --arg reason "$reason"
}

# autonomy_config_int <jq_path> <default>
# Reads an integer setting from .scrum/config.json at <jq_path> (a jq filter
# such as '.autonomous.max_iterations'). Returns <default> if config is
# absent, JSON unparseable, the path missing, or value not an integer.
autonomy_config_int() {
  local path="${1:-}"
  local default="${2:-0}"
  if [ -z "$path" ] || [ ! -f "$SCRUM_CONFIG_FILE" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! jq empty "$SCRUM_CONFIG_FILE" >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  local val
  # Use `// empty` so a JSON null collapses to empty string and we fall back.
  val="$(jq -r "($path) // empty" "$SCRUM_CONFIG_FILE" 2>/dev/null || echo "")"
  case "$val" in
    ''|*[!0-9-]*) printf '%s\n' "$default"; return 0 ;;
  esac
  # Accept optional leading minus, but stripped value must be all digits.
  case "${val#-}" in
    ''|*[!0-9]*) printf '%s\n' "$default"; return 0 ;;
  esac
  printf '%s\n' "$val"
}
