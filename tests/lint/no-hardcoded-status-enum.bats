#!/usr/bin/env bats
# tests/lint/no-hardcoded-status-enum.bats — the PBI status enum lives in
# docs/contracts/scrum-state/backlog.schema.json ONLY. Wrappers derive their
# allow-lists from the deployed schema at runtime (lib/queries.sh
# backlog_status_enum); a hardcoded parallel copy drifts when the enum grows
# (the `cancelled` incident: a deployed wrapper predating the value rejected
# it while the schema allowed it). Policy SUBSETS (e.g. "which statuses
# permit worktree cleanup") may stay hardcoded, but every value they name
# must be a member of the schema enum.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json"
}

@test "no-hardcoded-status-enum: update-backlog-status.sh has no duplicated allow-list" {
  # A mid-enum, Dev-managed value has no business appearing in this wrapper —
  # it neither sets a specific status nor documents actor ownership. Its
  # presence would mean the schema enum got re-hardcoded.
  run grep -c "in_progress_ut_run" "$PROJECT_ROOT/scripts/scrum/update-backlog-status.sh"
  [ "$output" = "0" ]
}

@test "no-hardcoded-status-enum: cleanup-pbi-worktree terminal subset is within the schema enum" {
  enum="$(jq -r '.properties.items.items.properties.status.enum[]' "$SCHEMA")"
  [ -n "$enum" ]
  # The terminal-status case arm (policy subset, intentionally hardcoded).
  line="$(grep -m1 -E '^[[:space:]]*awaiting_cross_review\|' \
    "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh")"
  [ -n "$line" ]
  values="$(printf '%s' "$line" | sed 's/).*//' | tr -d '[:space:]' | tr '|' '\n')"
  [ -n "$values" ]
  while IFS= read -r v; do
    printf '%s\n' "$enum" | grep -Fxq "$v" || {
      echo "cleanup-pbi-worktree.sh names '$v' which is not in the schema enum" >&2
      return 1
    }
  done <<< "$values"
}
