#!/usr/bin/env bash
# scripts/scrum/init-pbi-state.sh — initialise per-PBI pipeline state.
# Usage: init-pbi-state.sh <pbi-id>
#
# Creates `.scrum/pbi/<pbi-id>/state.json` with all required fields seeded
# (rounds = 0, statuses = pending, escalation_reason = null) plus the
# standard subdirectories (design/impl/ut/metrics/feedback).
#
# Idempotent: if state.json already exists and validates, succeeds without
# touching it. No exemption mechanism exists in the scrum-state guard (the
# v1 whitelist was deliberately removed) — like every other wrapper, this
# script simply passes the guard's pattern check naturally by invoking
# `.scrum/scripts/*` / `scripts/scrum/*`, and is the only sanctioned writer
# for the initial file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: init-pbi-state.sh <pbi-id>"
PBI="$1"
assert_pbi_id "$PBI"

PBI_DIR=".scrum/pbi/$PBI"
PATHF="$PBI_DIR/state.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}

if [ -f "$PATHF" ]; then
  if err="$(_validate_against_schema "$PATHF" "$SCHEMA" 2>&1)"; then
    exit 0
  fi
  fail E_SCHEMA "$PATHF exists but violates schema: $err"
fi

NOW="$(_iso_utc_now)"
# shellcheck disable=SC2016  # $id/$now are jq variables, expanded by jq -n --arg
atomic_create "$PATHF" "$SCHEMA" '{
  pbi_id: $id,
  design_round: 0,
  impl_round: 0,
  design_status: "pending",
  impl_status: "pending",
  ut_status: "pending",
  coverage_status: "pending",
  escalation_reason: null,
  started_at: $now,
  updated_at: $now
}' --arg id "$PBI" --arg now "$NOW"
