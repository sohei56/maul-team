#!/usr/bin/env bash
# scripts/scrum/run-detectors.sh — run the guard-first audit detectors
# registered in .scrum/audit-ledger.json.
#
# A detector is one shell command that mechanically proves a codebase-audit
# defect CLASS cannot recur. Registration and promotion live in the ledger
# (`classes[].detector`, written only by update-audit-ledger.sh); this runner
# never writes state and records results nowhere new — the caller decides what
# a non-zero exit means: merge-pbi.sh fails the merge with
# `merge_failure.kind=detector_regression`, and the smoke-test skill records
# one `detectors` category through record-test-result.sh.
#
# Usage:
#   run-detectors.sh [--check <identity>] [--json]
#
#   (no flags)        run every class with status == "guarded"
#   --check <id>      run exactly ONE class's detector regardless of its
#                     status. This is the machine "wired" probe used by
#                     update-audit-ledger.sh `set-status guarded` and by a
#                     detector PBI's own acceptance criteria.
#   --json            emit a machine-readable result document on stdout
#                     instead of the human log.
#
# Exit codes — the contract consumers branch on. This is DISTINCT from
# lib/errors.sh `fail` (64..67); the one deliberate coincidence is that a
# usage error is E_INVALID_ARG, which is already 64.
#   0   every selected detector reported clean (also: nothing to run)
#   1   at least one detector reported violations
#   2   at least one detector COULD NOT EXECUTE — exit 127, killed by a
#       signal, timed out, or a guarded class with no registered command.
#       Never downgraded to "clean": fail-closed, because a ratchet that
#       silently passes while broken is the exact state this gate exists to
#       prevent.
#   64  usage error (unknown flag, malformed identity, class not in the ledger)
#
# Silence is load-bearing. A target with no ledger, or with no guarded class,
# prints nothing and exits 0 — every project that has not adopted guard-first
# detectors must see byte-identical merge behaviour, not a WARN per merge.
# `--json` is the exception: a machine caller that explicitly asked for a
# document always gets a valid one (with an empty `detectors` array), which is
# how the smoke-test skill tells "no guarded classes" from "all clean".
#
# Detector contract + how a detector PBI is written:
# skills/codebase-audit/references/detectors.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"   # assert_audit_identity + fail (E_INVALID_ARG = 64)

LEDGER=".scrum/audit-ledger.json"
CHECK=""
JSON=0

usage() {
  fail E_INVALID_ARG "$* (usage: run-detectors.sh [--check <identity>] [--json])"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      [ "$#" -ge 2 ] || usage "--check requires an <identity>"
      CHECK="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) usage "unknown flag: $1" ;;
  esac
done

# Per-detector wall-clock budget. Bash 3.2 has no portable timeout(1), so the
# bound is enforced by a background job plus a `kill -0` poll loop below.
TIMEOUT=120
if [ -f .scrum/config.json ]; then
  CFG_TIMEOUT="$(jq -r '.detectors.timeout_seconds // empty' .scrum/config.json 2>/dev/null || true)"
  case "$CFG_TIMEOUT" in
    ''|*[!0-9]*) ;;
    *) [ "$CFG_TIMEOUT" -gt 0 ] && TIMEOUT="$CFG_TIMEOUT" ;;
  esac
fi

# Poll granularity. Fractional sleep is not POSIX, but both BSD and GNU sleep
# accept it; probe once and fall back to whole seconds so a detector that
# finishes in milliseconds does not cost a second per merge.
SLEEP_UNIT=1
TICKS_PER_SEC=1
if sleep 0.1 >/dev/null 2>&1; then
  SLEEP_UNIT=0.1
  TICKS_PER_SEC=10
fi

emit_empty_and_exit() {
  if [ "$JSON" = "1" ]; then
    jq -n --argjson timeout "$TIMEOUT" '{exit: 0, timeout_seconds: $timeout, detectors: []}'
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Select the classes to run.
# ---------------------------------------------------------------------------
IDENTS=()
if [ -n "$CHECK" ]; then
  # Reject, never repair: the identity form is the one lib/errors.sh already
  # enforces at issuance, so the ledger and this probe cannot disagree.
  ( assert_audit_identity "$CHECK" --check ) || exit 64
  [ -f "$LEDGER" ] || usage "no ledger at $LEDGER — nothing to check for '$CHECK'"
  if [ "$(jq --arg k "$CHECK" '[.classes[]? | select(.identity == $k)] | length' "$LEDGER")" -eq 0 ]; then
    usage "identity '$CHECK' is not a class in $LEDGER"
  fi
  IDENTS=("$CHECK")
else
  [ -f "$LEDGER" ] || emit_empty_and_exit
  while IFS= read -r ident; do
    [ -n "$ident" ] || continue
    IDENTS+=("$ident")
  done < <(jq -r '.classes[]? | select(.status == "guarded") | .identity' "$LEDGER")
  [ "${#IDENTS[@]}" -gt 0 ] || emit_empty_and_exit
fi

# ---------------------------------------------------------------------------
# _run_bounded <command> <outfile>
# Run <command> via `bash -c` from the repo root with stdin closed, capturing
# stdout+stderr into <outfile>. Returns the command's exit status, or 124 when
# the budget expired (TERM, then KILL).
# ---------------------------------------------------------------------------
_run_bounded() {
  local cmd="$1" out="$2"
  local pid ticks max_ticks rc
  bash -c "$cmd" >"$out" 2>&1 </dev/null &
  pid=$!
  ticks=0
  max_ticks=$((TIMEOUT * TICKS_PER_SEC))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep "$SLEEP_UNIT"
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$SLEEP_UNIT"
    ticks=$((ticks + 1))
  done
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-detectors.XXXXXX")"
# shellcheck disable=SC2064  # expand WORK now: the trap must not depend on later state
trap "rm -rf '$WORK'" EXIT

WORST=0
ENTRIES='[]'
for ident in "${IDENTS[@]}"; do
  CMD="$(jq -r --arg k "$ident" \
    '[.classes[]? | select(.identity == $k) | (.detector.command // "")][0] // ""' "$LEDGER")"

  OUT="$WORK/out"
  : >"$OUT"
  if [ -z "$CMD" ]; then
    # A guarded class with no registered command cannot be checked. That is an
    # infrastructure failure, not a pass — the ledger claims a ratchet that is
    # not there.
    RC=126
    OUTCOME=unexecutable
    REASON="no detector.command registered in $LEDGER"
  else
    RC=0
    _run_bounded "$CMD" "$OUT" || RC=$?
    case "$RC" in
      0)   OUTCOME=clean;        REASON="" ;;
      124) OUTCOME=unexecutable; REASON="timed out after ${TIMEOUT}s" ;;
      127) OUTCOME=unexecutable; REASON="command not found (exit 127)" ;;
      [1-9]|[1-9][0-9]|1[01][0-9]|12[0-6])
           OUTCOME=violations;   REASON="" ;;
      *)   OUTCOME=unexecutable; REASON="terminated abnormally (exit $RC)" ;;
    esac
  fi

  # First 50 lines per detector — enough to name the offending sites without
  # letting one noisy detector bury the rest of the log.
  OUTTEXT="$(head -n 50 "$OUT" | tr -d '\000')"

  if [ "$JSON" = "1" ]; then
    ENTRIES="$(jq -c -n \
      --argjson acc "$ENTRIES" \
      --arg identity "$ident" \
      --arg command "$CMD" \
      --argjson code "$RC" \
      --arg outcome "$OUTCOME" \
      --arg reason "$REASON" \
      --arg out "$OUTTEXT" \
      '$acc + [{identity: $identity, command: $command, exit: $code, outcome: $outcome,
                reason: (if $reason == "" then null else $reason end),
                output: (if $out == "" then [] else ($out | split("\n")) end)}]')"
  else
    case "$OUTCOME" in
      clean) ;;   # silence on success — see the header
      violations)
        if [ -n "$OUTTEXT" ]; then
          printf '%s\n' "$OUTTEXT" | sed "s|^|[$ident] |"
        else
          printf '[%s] detector reported violations (exit %s) but wrote no output\n' "$ident" "$RC"
        fi
        ;;
      unexecutable)
        printf '[%s] DETECTOR COULD NOT EXECUTE: %s\n' "$ident" "$REASON"
        [ -z "$OUTTEXT" ] || printf '%s\n' "$OUTTEXT" | sed "s|^|[$ident] |"
        ;;
    esac
  fi

  case "$OUTCOME" in
    unexecutable) WORST=2 ;;
    violations)   [ "$WORST" -eq 2 ] || WORST=1 ;;
  esac
done

if [ "$JSON" = "1" ]; then
  jq -n --argjson timeout "$TIMEOUT" --argjson code "$WORST" --argjson detectors "$ENTRIES" \
    '{exit: $code, timeout_seconds: $timeout, detectors: $detectors}'
fi

exit "$WORST"
