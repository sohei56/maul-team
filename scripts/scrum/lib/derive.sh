#!/usr/bin/env bash
# scripts/scrum/lib/derive.sh — single source of truth for the
# pbi/state.json.phase → backlog.json items[].status mapping.
#
# Sourced by scripts/scrum/*.sh. Pure function: no I/O, no logging.

if [ "${_SCRUM_DERIVE_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi
_SCRUM_DERIVE_SH_LOADED=1

# derive_backlog_status_from_phase <phase>
# Echoes the corresponding backlog.json items[].status. Exits non-zero on
# unknown phase (caller decides whether to fail or fall back).
derive_backlog_status_from_phase() {
  case "$1" in
    design)                 echo "in_progress" ;;
    impl_ut)                echo "in_progress" ;;
    complete)               echo "review" ;;
    ready_to_merge)         echo "review" ;;
    merged)                 echo "review" ;;
    merge_conflict)         echo "review" ;;
    merge_artifact_missing) echo "review" ;;
    merge_regression)       echo "review" ;;
    review_complete)        echo "done" ;;
    escalated)              echo "blocked" ;;
    *) return 1 ;;
  esac
}

# is_post_pipeline_status <status>
# Returns 0 (true) when the given backlog status represents a state that
# only the pbi-pipeline / cross-review flow may set. Returns 1 (false)
# for the pre-pipeline values (draft, refined) which skills set directly.
is_post_pipeline_status() {
  case "$1" in
    in_progress|review|done|blocked) return 0 ;;
    *) return 1 ;;
  esac
}
