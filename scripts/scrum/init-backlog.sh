#!/usr/bin/env bash
# scripts/scrum/init-backlog.sh — bootstrap .scrum/backlog.json at
# Requirement Definition exit.
# Usage: init-backlog.sh [--product-goal <text>]
#
# Creates `.scrum/backlog.json` with `{items: [], next_pbi_id: 1,
# product_goal: <text or null>}`. The SM then appends coarse PBIs via
# `add-backlog-item.sh`, which requires the file to already exist.
#
# Idempotent: if `.scrum/backlog.json` already exists, prints a no-op
# message and exits 0 without touching the file. NEVER overwrites —
# double-bootstrap is benign, drift-clobber is not.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

PRODUCT_GOAL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --product-goal)
      [ "$#" -ge 2 ] || fail E_INVALID_ARG "--product-goal needs value"
      PRODUCT_GOAL="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

PATHF=".scrum/backlog.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"

if [ -f "$PATHF" ]; then
  printf '[init-backlog] %s already exists — no changes\n' "$PATHF"
  exit 0
fi

mkdir -p .scrum

# shellcheck disable=SC2016  # $goal is a jq variable, expanded by jq -n --arg
atomic_create "$PATHF" "$SCHEMA" '{
  items: [],
  next_pbi_id: 1,
  product_goal: (if $goal == "" then null else $goal end)
}' --arg goal "$PRODUCT_GOAL"

printf '[init-backlog] created %s (next_pbi_id=1)\n' "$PATHF"
