#!/usr/bin/env bash
# scripts/scrum/record-test-result.sh — record one TestCategory into
# .scrum/test-results.json and recompute overall_status.
#
# Usage:
#   record-test-result.sh \
#     --name <category> \
#     --status <passed|failed|skipped> \
#     [--total <int>] \
#     [--passed <int>] \
#     [--failed <int>] \
#     [--skipped <int>] \
#     [--runner-command <text>] \
#     [--executed-at <iso8601>]     # defaults to now (UTC)
#     [--error 'TEST_NAME::message'] # repeatable, max 10; ::-less value is
#                                    # taken as message-only
#
# Categories are keyed by --name: recording a category that already exists
# REPLACES it (a re-run of a suite after a fix yields fresh counts, so the
# release gate must see the latest result, not a stale failing duplicate).
# Distinct names append. overall_status is recomputed on every call:
#   any category failed         -> "failed"
#   else any category skipped   -> "passed_with_skips"
#   else                        -> "passed"
# Both the smoke-test skill (one call per detected suite) and the
# integration-tests skill (one call per category: integration_api /
# integration_ui / design_coverage / manual_probe) write through this
# wrapper; direct edits to .scrum/test-results.json are blocked by
# pre-tool-use-scrum-state-guard.sh.
#
# Schema: docs/contracts/scrum-state/test-results.schema.json.
#
# The store file is created on first call (initial content
# `{"categories": [], "overall_status": "running", ...}`) and the parent
# directory `.scrum/` is created automatically. started_at is set on create
# and preserved; updated_at is refreshed by atomic_write on every call.
#
# Echoes the recomputed overall_status on stdout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

NAME=""
STATUS=""
TOTAL=""
PASSED=""
FAILED=""
SKIPPED=""
RUNNER=""
EXECUTED_AT=""
ERRORS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)            NAME="$2"; shift 2 ;;
    --status)          STATUS="$2"; shift 2 ;;
    --total)           TOTAL="$2"; shift 2 ;;
    --passed)          PASSED="$2"; shift 2 ;;
    --failed)          FAILED="$2"; shift 2 ;;
    --skipped)         SKIPPED="$2"; shift 2 ;;
    --runner-command)  RUNNER="$2"; shift 2 ;;
    --executed-at)     EXECUTED_AT="$2"; shift 2 ;;
    --error)           ERRORS+=("$2"); shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

[ -n "$NAME" ]   || fail E_INVALID_ARG "--name required"
[ -n "$STATUS" ] || fail E_INVALID_ARG "--status required"

case "$STATUS" in
  passed|failed|skipped) ;;
  *) fail E_INVALID_ARG "bad --status: $STATUS (expected passed|failed|skipped)" ;;
esac

for pair in "total:$TOTAL" "passed:$PASSED" "failed:$FAILED" "skipped:$SKIPPED"; do
  flag="${pair%%:*}"; val="${pair#*:}"
  [ -n "$val" ] || continue
  case "$val" in
    *[!0-9]*) fail E_INVALID_ARG "bad --$flag: $val (expected non-negative integer)" ;;
  esac
done

if [ "${#ERRORS[@]}" -gt 10 ]; then
  fail E_INVALID_ARG "too many --error entries: ${#ERRORS[@]} (max 10)"
fi

# Build the errors[] JSON from repeatable --error flags. Each value is split on
# the first "::" into {test_name, message}; a value without "::" is message-only.
ERRORS_JSON='[]'
if [ "${#ERRORS[@]}" -gt 0 ]; then
  for e in "${ERRORS[@]}"; do
    case "$e" in
      *::*)
        tn="${e%%::*}"; msg="${e#*::}"
        ERRORS_JSON="$(jq -c --argjson arr "$ERRORS_JSON" --arg tn "$tn" --arg msg "$msg" \
          '$arr + [{test_name: $tn, message: $msg}]' <<<'null')"
        ;;
      *)
        ERRORS_JSON="$(jq -c --argjson arr "$ERRORS_JSON" --arg msg "$e" \
          '$arr + [{message: $msg}]' <<<'null')"
        ;;
    esac
  done
fi

[ -n "$EXECUTED_AT" ] || EXECUTED_AT="$(_iso_utc_now)"

# Build the TestCategory record via jq -n so all free-form text is escaped.
# Optional numeric/string fields are omitted (not null) when not supplied.
REC_JSON="$(
  jq -n \
    --arg name "$NAME" \
    --arg status "$STATUS" \
    --arg total "$TOTAL" \
    --arg passed "$PASSED" \
    --arg failed "$FAILED" \
    --arg skipped "$SKIPPED" \
    --arg runner "$RUNNER" \
    --arg executed_at "$EXECUTED_AT" \
    --argjson errors "$ERRORS_JSON" \
    '{ name: $name, status: $status, executed_at: $executed_at }
     + (if $total   == "" then {} else { total:   ($total   | tonumber) } end)
     + (if $passed  == "" then {} else { passed:  ($passed  | tonumber) } end)
     + (if $failed  == "" then {} else { failed:  ($failed  | tonumber) } end)
     + (if $skipped == "" then {} else { skipped: ($skipped | tonumber) } end)
     + (if $runner  == "" then {} else { runner_command: $runner } end)
     + (if ($errors | length) == 0 then {} else { errors: $errors } end)'
)"

PATHF=".scrum/test-results.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/test-results.schema.json"
mkdir -p "$(dirname "$PATHF")"
if [ ! -f "$PATHF" ]; then
  # Seed through atomic_create so the first write is schema-validated and lands
  # via temp+mv, matching the atomic_write mutation that follows.
  NOW="$(_iso_utc_now)"
  # shellcheck disable=SC2016  # $now is a jq -n var (atomic_create passes --arg now), not a shell var
  atomic_create "$PATHF" "$SCHEMA" \
    '{categories: [], overall_status: "running", started_at: $now, updated_at: $now}' \
    --arg now "$NOW"
fi

# Upsert the category by name, then recompute overall_status from all categories.
# shellcheck disable=SC2016  # $rec is a jq binding, not a shell variable.
EXPR='('"$REC_JSON"') as $rec
  | .categories = (((.categories // []) | map(select(.name != $rec.name))) + [$rec])
  | .overall_status = (
      if   (.categories | any(.status == "failed"))  then "failed"
      elif (.categories | any(.status == "skipped")) then "passed_with_skips"
      else "passed" end
    )'

atomic_write "$PATHF" "$EXPR" "$SCHEMA"

jq -r '.overall_status' "$PATHF"
