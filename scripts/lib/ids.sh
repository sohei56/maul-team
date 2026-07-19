#!/usr/bin/env bash
# scripts/lib/ids.sh — shared identity/digest helpers for the launcher process
# family (scrum-start.sh and scripts/autonomous/watchdog.sh).
#
# Both consumers run in-place from the framework repo (scrum-start.sh launches
# the watchdog via $SCRIPT_DIR/scripts/...), so this lib always travels with
# them — same deployment reasoning as scripts/lib/jq-read.sh / time.sh. The
# no-cross-source convention between scripts/ and hooks/lib/ does not apply
# within this single family.
#
# Requires scripts/lib/time.sh sourced first (generate_uuid's last-resort
# fallback calls now_epoch).
#
# Bash 3.2 compatible. shellcheck clean.

# Guard against double-sourcing.
# shellcheck disable=SC2317
if [ "${_IDS_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_IDS_SH_LOADED=1

# generate_uuid — Bash 3.2-compatible UUID v4 generator
# (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx). Prefers uuidgen; falls back to
# /dev/urandom hex, then to an epoch+pid+RANDOM synthesis.
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

# portable_sha1 — read stdin, emit a digest usable as a stable fingerprint.
# Three-way portable fallback chain: shasum (macOS) → sha1sum (GNU) → cksum
# (POSIX last resort; emits a CRC, not a sha — still stable, just weaker).
# Emits the first whitespace-separated field of the tool's output.
portable_sha1() {
  if command -v shasum >/dev/null 2>&1; then
    shasum | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}
