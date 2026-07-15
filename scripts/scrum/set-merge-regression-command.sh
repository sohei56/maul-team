#!/usr/bin/env bash
# scripts/scrum/set-merge-regression-command.sh — record the per-PBI merge
# regression gate command in .scrum/config.json.
# Usage:
#   set-merge-regression-command.sh <command-string>   # configure the gate
#   set-merge-regression-command.sh --none             # deliberately no gate
#
# merge-pbi.sh runs `.merge_regression.command` after every per-PBI merge.
# When it is unset the gate is silently skipped, and — because a console WARN
# is read by nobody in autonomous mode — a target project shipped a broken
# test suite to main Sprint after Sprint. This wrapper turns that silent
# default into an explicit, logged decision made at Sprint Planning
# (see skills/sprint-planning/SKILL.md Step 11.5):
#   <command>  → sets .merge_regression.command and clears accepted_none.
#   --none     → sets .merge_regression.command = null AND
#                .merge_regression.accepted_none = true, so a deliberate
#                "no gate" is distinguishable from a never-decided unset one
#                (merge-pbi.sh then drops its WARN to a quiet note).
#
# Direct edits to .scrum/config.json are blocked by the scrum-state PreToolUse
# guard; this is the sanctioned writer.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: set-merge-regression-command.sh <command-string> | --none"

ARG="$1"
PATHF=".scrum/config.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/config.schema.json"

if [ "$ARG" = "--none" ]; then
  CMD_JSON="null"
  ACCEPTED_NONE="true"
else
  case "$ARG" in
    --*) fail E_INVALID_ARG "unknown flag: $ARG (only --none is recognized; pass a command string otherwise)" ;;
  esac
  [ -n "$ARG" ] || fail E_INVALID_ARG "command must be non-empty; use --none to record no gate"
  # Render the command as a properly-escaped JSON string literal so it can be
  # interpolated into the jq program without injection (mirrors the VALUE_JSON
  # convention in set-sprint-developer.sh).
  CMD_JSON="$(jq -n --arg c "$ARG" '$c')"
  ACCEPTED_NONE="false"
fi

if [ -f "$PATHF" ]; then
  # Preserve any sibling merge_regression sub-keys (additionalProperties:true).
  EXPR='.merge_regression = ((.merge_regression // {}) | .command = '"$CMD_JSON"' | .accepted_none = '"$ACCEPTED_NONE"')'
  atomic_write "$PATHF" "$EXPR" "$SCHEMA"
else
  mkdir -p .scrum
  atomic_create "$PATHF" "$SCHEMA" \
    '{merge_regression: {command: '"$CMD_JSON"', accepted_none: '"$ACCEPTED_NONE"'}}'
fi

if [ "$ACCEPTED_NONE" = "true" ]; then
  printf '[set-merge-regression-command] recorded no per-PBI regression gate (accepted_none=true)\n'
else
  printf '[set-merge-regression-command] merge_regression.command set to: %s\n' "$ARG"
fi
