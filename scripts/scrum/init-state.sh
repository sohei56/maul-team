#!/usr/bin/env bash
# scripts/scrum/init-state.sh — bootstrap .scrum/state.json for a fresh project.
# Usage: init-state.sh
#
# Creates `.scrum/state.json` with the seed shape
# (phase="new", current_sprint_id=null, product_goal=null) so the very first
# `update-state-phase.sh requirements_sprint` call has a file to mutate.
# Without this wrapper the SM dead-ends on a freshly-registered target
# project: atomic_write requires the file to exist (E_FILE_MISSING) and the
# scrum-state PreToolUse guard blocks raw writes to `.scrum/*.json`.
#
# Idempotent: if `.scrum/state.json` already exists, prints a no-op message
# and exits 0 without touching the file. NEVER overwrites — double-bootstrap
# is benign, drift-clobber is not.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 0 ] || fail E_INVALID_ARG "usage: init-state.sh"

PATHF=".scrum/state.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/state.schema.json"

if [ -f "$PATHF" ]; then
  printf '[init-state] %s already exists — no changes\n' "$PATHF"
  exit 0
fi

mkdir -p .scrum

NOW="$(_iso_utc_now)"
# shellcheck disable=SC2016  # $now is a jq variable, expanded by jq -n --arg
atomic_create "$PATHF" "$SCHEMA" '{
  phase: "new",
  current_sprint_id: null,
  product_goal: null,
  created_at: $now,
  updated_at: $now
}' --arg now "$NOW"

printf '[init-state] created %s (phase=new)\n' "$PATHF"
