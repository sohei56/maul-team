#!/usr/bin/env bash
# stop-gate-state.sh — Stop-hook dedup ledger for human-mode block suppression.
#
# Records the last seen <phase, fingerprint> pair plus a block counter at
# .scrum/stop-gate.json so completion-gate.sh can collapse repeated identical
# Stop blocks into a single notification per situation. Without this, the SM
# session is re-blocked every turn-end while the underlying condition (e.g.
# "no sprint history entry yet") persists, burning context.
#
# Schema:
#   {
#     "phase": str,
#     "fingerprint": str,
#     "block_count": int,
#     "first_block_at": iso8601,
#     "last_block_at": iso8601
#   }
#
# Public API:
#   stop_gate_check_and_bump <fingerprint> <phase>
#     Emits one of:
#       FIRST          — new fingerprint OR phase changed OR file missing/broken
#       REPEAT:<N>     — same <phase, fingerprint> as last record (N = new count)
#     Caller policy: on FIRST emit the verbose block; on REPEAT suppress.
#
# Fail-open semantics: on any I/O / JSON failure we emit FIRST (block side).
# Allowing on failure would silently disable the gate; blocking is safer.
#
# Design notes:
#   - Bash 3.2 compatible: no associative arrays, no namerefs, no `${var^^}`.
#   - This file lives under hooks/lib/ and writes .scrum/stop-gate.json
#     directly. That path is NOT covered by pre-tool-use-scrum-state-guard.sh
#     (the guard only intercepts Bash tool calls from agents; hook scripts
#     invoked by the harness run outside that guard).
#   - Writes are atomic via tmp + mv.
#
# Guard against double-sourcing.
# shellcheck disable=SC2317
if [ "${_STOP_GATE_STATE_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_STOP_GATE_STATE_SH_LOADED=1

STOP_GATE_FILE=".scrum/stop-gate.json"

# ISO-8601 UTC timestamp. Mirrors hooks/lib/validate.sh::get_timestamp; we
# duplicate so this lib can be sourced without validate.sh.
_stop_gate_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

# _stop_gate_ensure_dir
# Make sure .scrum/ exists before any write. Silent on success.
_stop_gate_ensure_dir() {
  if [ ! -d ".scrum" ]; then
    mkdir -p ".scrum" 2>/dev/null || return 1
  fi
  return 0
}

# _stop_gate_write <jq_program> [jq_args...]
# Single atomic writer for stop-gate.json (the tmp+mv idiom lived here twice;
# now parameterized by the jq program). Renders <jq_program> — with $now bound
# to the current timestamp plus any extra --arg/--argjson pairs — into a tmp
# sibling and mv's it into place. Uses the existing file as jq input when it
# is present and parseable, and `jq -n` (fresh document) otherwise. Returns 1
# on any failure so callers can fail-open toward FIRST.
_stop_gate_write() {
  local prog="$1"
  shift
  local now tmp
  now="$(_stop_gate_now)"
  _stop_gate_ensure_dir || return 1
  tmp="${STOP_GATE_FILE}.tmp.$$.${RANDOM}"
  if [ -f "$STOP_GATE_FILE" ] && jq empty "$STOP_GATE_FILE" >/dev/null 2>&1; then
    jq --arg now "$now" "$@" "$prog" "$STOP_GATE_FILE" > "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      return 1
    }
  else
    jq -n --arg now "$now" "$@" "$prog" > "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      return 1
    }
  fi
  mv "$tmp" "$STOP_GATE_FILE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# _stop_gate_write_first <fingerprint> <phase>
# Write a fresh record with block_count=1 (the program constructs the whole
# document, so any prior record is replaced). On any error the caller falls
# back to emitting FIRST (fail-open toward block).
_stop_gate_write_first() {
  # shellcheck disable=SC2016  # $phase/$fp/$now are jq variables
  _stop_gate_write '{
      phase: $phase,
      fingerprint: $fp,
      block_count: 1,
      first_block_at: $now,
      last_block_at: $now
    }' \
    --arg fp "$1" \
    --arg phase "$2"
}

# _stop_gate_write_bump <new_count>
# Bump block_count to <new_count> + refresh last_block_at, preserving
# phase / fingerprint / first_block_at.
_stop_gate_write_bump() {
  # shellcheck disable=SC2016  # $n/$now are jq variables
  _stop_gate_write '.block_count = $n | .last_block_at = $now' \
    --argjson n "$1"
}

# stop_gate_check_and_bump <fingerprint> <phase>
# Public entry point — see header. Bash 3.2 safe (no `local -i`).
# Never returns non-zero; emits the verdict on stdout.
#
# IMPORTANT: callers may have `set -e` active. The function is structured so
# every failure path falls through to printing FIRST without leaving a
# non-zero exit status.
stop_gate_check_and_bump() {
  local fp="${1:-}"
  local phase="${2:-}"

  # Defensive: empty inputs collapse to FIRST so the caller never silently
  # treats a parameter-bug as a "repeat" (which would mute the gate).
  if [ -z "$fp" ] || [ -z "$phase" ]; then
    printf '%s\n' "FIRST"
    return 0
  fi

  # No record yet OR record unreadable → write FIRST.
  if [ ! -f "$STOP_GATE_FILE" ] || ! jq empty "$STOP_GATE_FILE" >/dev/null 2>&1; then
    # Fail-open toward block: emit FIRST whether or not the write succeeds.
    _stop_gate_write_first "$fp" "$phase" || true
    printf '%s\n' "FIRST"
    return 0
  fi

  local prev_phase prev_fp prev_count
  prev_phase="$(jq -r '.phase // ""' "$STOP_GATE_FILE" 2>/dev/null || echo "")"
  prev_fp="$(jq -r '.fingerprint // ""' "$STOP_GATE_FILE" 2>/dev/null || echo "")"
  prev_count="$(jq -r '.block_count // 0' "$STOP_GATE_FILE" 2>/dev/null || echo "0")"

  # Validate prev_count is a non-negative integer; treat anything else as 0.
  case "$prev_count" in
    ''|*[!0-9]*) prev_count="0" ;;
  esac

  if [ "$prev_phase" != "$phase" ] || [ "$prev_fp" != "$fp" ]; then
    # Situation changed → reset. Fail-open toward block regardless of write.
    _stop_gate_write_first "$fp" "$phase" || true
    printf '%s\n' "FIRST"
    return 0
  fi

  # Same situation → bump counter.
  local new_count
  new_count=$((prev_count + 1))
  if _stop_gate_write_bump "$new_count"; then
    printf 'REPEAT:%s\n' "$new_count"
  else
    # Write failed but state was readable; fail-open toward block so the
    # session does not silently exit while the condition persists.
    printf '%s\n' "FIRST"
  fi
  return 0
}
