#!/usr/bin/env bash
# scripts/scrum/update-pbi-state.sh — variadic field=value setter for PBI pipeline state.
# Usage: update-pbi-state.sh <pbi-id> <field> <value> [<field> <value> ...]
#
# Mutates .scrum/pbi/<pbi-id>/state.json. All field/value pairs apply in a single
# atomic_write — one transaction, one schema validation, one mv. The schema's
# `additionalProperties: false` plus the local enum/integer checks here mean a
# single typo fails the whole batch (intentional).
#
# Writable fields (see docs/contracts/scrum-state/pbi-state.schema.json):
#   design_round      integer >= 0
#   impl_round        integer >= 0
#   design_status     pending|in_review|fail|pass|skipped
#   impl_status       pending|in_review|fail|pass
#   ut_status         pending|in_review|fail|pass|skipped
#   coverage_status   pending|fail|pass|skipped
#   escalation_reason null|stagnation|divergence|max_rounds|budget_exhausted|
#                     requirements_unclear|coverage_tool_error|
#                     coverage_tool_unavailable|catalog_lock_timeout|
#                     reviewer_unavailable|stale_review_snapshot|
#                     merge_conflict|merge_artifact_missing|merge_regression|
#                     kind_mismatch
#
# skipped is the canonical value for stages a kind=docs PBI never runs
# (design / UT author / UT execution / coverage). kind_mismatch is the
# escalation reason emitted by mark-pbi-ready-to-merge.sh when a
# kind=docs PBI has paths_touched outside *.md.
#   branch            pbi/pbi-NNN (validated: must match pbi/pbi-[0-9]*)
#   worktree          .scrum/worktrees/pbi-NNN (validated)
#   base_sha          hex sha, 7..40 chars
#   head_sha          hex sha, 7..40 chars
#   merged_sha        hex sha, 7..40 chars
#   ready_at          ISO-8601 datetime string
#   merged_at         ISO-8601 datetime string
#   merge_failure_count  non-negative integer
#   websearch_attempted  true|false (once-per-PBI web-search remediation latch)
#   merge_failure        null only (drops the object). Non-null values
#                        of merge_failure are written by
#                        mark-pbi-merge-failure.sh, not here. The retry
#                        path in pbi-escalation-handler resets both the
#                        count and the object atomically; without this
#                        allowlist entry the object would survive a
#                        count=0 reset and read as a live failure
#                        record to dashboards / gates mid-retry.
#
# pbi_id, started_at, updated_at are NOT settable here.
# updated_at is auto-stamped by atomic_write.
# Complex fields (paths_touched, non-null merge_failure) use dedicated wrappers.
# Backlog status is written via update-backlog-status.sh (no projection here).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

[ "$#" -ge 3 ] || fail E_INVALID_ARG "usage: update-pbi-state.sh <pbi-id> <field> <value> [<field> <value> ...]"
PBI="$1"; shift
assert_pbi_id "$PBI"

PATHF=".scrum/pbi/$PBI/state.json"
[ -f "$PATHF" ] || fail E_FILE_MISSING "$PATHF (initialise via pbi-pipeline first)"

# Pair count must be even.
if [ $(( $# % 2 )) -ne 0 ]; then
  fail E_INVALID_ARG "field/value args must be paired (got odd count)"
fi

# Build the jq expression by accumulating per-pair sub-expressions. All field
# names and value literals below pass strict case-pattern whitelists, so direct
# interpolation is safe (no shell or jq injection risk).
EXPR="."
while [ "$#" -ge 2 ]; do
  F="$1"; V="$2"; shift 2
  case "$F" in
    design_round|impl_round)
      case "$V" in
        ''|*[!0-9]*) fail E_INVALID_ARG "$F must be non-negative integer (got: $V)" ;;
      esac
      EXPR="$EXPR | .$F = $V"
      ;;
    design_status|ut_status)
      case "$V" in
        pending|in_review|fail|pass|skipped) ;;
        *) fail E_INVALID_ARG "bad $F: $V" ;;
      esac
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    impl_status)
      case "$V" in
        pending|in_review|fail|pass) ;;
        *) fail E_INVALID_ARG "bad $F: $V" ;;
      esac
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    coverage_status)
      case "$V" in
        pending|fail|pass|skipped) ;;
        *) fail E_INVALID_ARG "bad coverage_status: $V" ;;
      esac
      EXPR="$EXPR | .coverage_status = \"$V\""
      ;;
    escalation_reason)
      case "$V" in
        null) EXPR="$EXPR | .escalation_reason = null" ;;
        stagnation|divergence|max_rounds|budget_exhausted|requirements_unclear|coverage_tool_error|coverage_tool_unavailable|catalog_lock_timeout|reviewer_unavailable|stale_review_snapshot|merge_conflict|merge_artifact_missing|merge_regression|kind_mismatch)
          EXPR="$EXPR | .escalation_reason = \"$V\""
          ;;
        *) fail E_INVALID_ARG "bad escalation_reason: $V" ;;
      esac
      ;;
    branch)
      case "$V" in
        pbi/pbi-[0-9]*) ;;
        *) fail E_INVALID_ARG "bad branch (must be pbi/pbi-NNN): $V" ;;
      esac
      EXPR="$EXPR | .branch = \"$V\""
      ;;
    worktree)
      case "$V" in
        .scrum/worktrees/pbi-[0-9]*) ;;
        *) fail E_INVALID_ARG "bad worktree (must be .scrum/worktrees/pbi-NNN): $V" ;;
      esac
      EXPR="$EXPR | .worktree = \"$V\""
      ;;
    base_sha|head_sha|merged_sha)
      assert_hex_sha "$F" "$V"
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    ready_at|merged_at)
      # ISO-8601 sanity (full validation is left to the schema validator)
      case "$V" in
        [0-9][0-9][0-9][0-9]-*) ;;
        *) fail E_INVALID_ARG "$F must be ISO-8601: $V" ;;
      esac
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    merge_failure_count)
      case "$V" in
        ''|*[!0-9]*) fail E_INVALID_ARG "merge_failure_count must be non-negative integer (got: $V)" ;;
      esac
      EXPR="$EXPR | .merge_failure_count = $V"
      ;;
    websearch_attempted)
      case "$V" in
        true|false) ;;
        *) fail E_INVALID_ARG "websearch_attempted must be true or false (got: $V)" ;;
      esac
      EXPR="$EXPR | .websearch_attempted = $V"
      ;;
    merge_failure)
      # Only null is accepted here — non-null objects must go through
      # mark-pbi-merge-failure.sh which builds the kind/paths/pre_head triple.
      case "$V" in
        null) EXPR="$EXPR | del(.merge_failure)" ;;
        *) fail E_INVALID_ARG "merge_failure may only be set to 'null' via this wrapper (got: $V); non-null values are written by mark-pbi-merge-failure.sh" ;;
      esac
      ;;
    *) fail E_INVALID_ARG "unknown field: $F" ;;
  esac
done

atomic_write "$PATHF" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"
