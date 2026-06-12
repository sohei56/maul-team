#!/usr/bin/env bats
# state-schema.bats — Validates JSON state files against the schemas
# defined in data-model.md. Uses jq for field presence and type checks.

load '../test_helper/common-setup'

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

@test "valid state.json has all required fields" {
  local file="$FIXTURES_DIR/valid-state.json"

  # Each required field must be present and non-null
  run jq -e '.product_goal' "$file"
  assert_success

  run jq -e '.current_sprint_id' "$file"
  assert_success

  run jq -e '.phase' "$file"
  assert_success

  run jq -e '.created_at' "$file"
  assert_success

  run jq -e '.updated_at' "$file"
  assert_success
}

@test "state.json phase must be a valid enum value" {
  local file="$FIXTURES_DIR/valid-state.json"

  # The phase value must be one of the allowed enum values
  run jq -e '
    .phase as $p |
    ["new","requirements_sprint","backlog_created","sprint_planning",
     "pbi_pipeline_active","review","sprint_review",
     "retrospective","integration_sprint","complete"] |
    index($p) != null
  ' "$file"
  assert_success
}

@test "invalid state without phase field is detected" {
  local file="$FIXTURES_DIR/invalid-state-missing-phase.json"

  # .phase should not exist in the invalid fixture
  run jq -e '.phase' "$file"
  assert_failure
}

# ---------------------------------------------------------------------------
# backlog.json
# ---------------------------------------------------------------------------

@test "valid backlog has required fields" {
  local file="$FIXTURES_DIR/valid-backlog.json"

  run jq -e '.product_goal' "$file"
  assert_success

  run jq -e '.items | type == "array"' "$file"
  assert_success

  run jq -e '.next_pbi_id | type == "number"' "$file"
  assert_success
}

@test "PBI has required fields" {
  local file="$FIXTURES_DIR/valid-backlog.json"

  # Check every required field on the first PBI
  run jq -e '.items[0] | (
    .id != null and
    .title != null and
    .description != null and
    .acceptance_criteria != null and
    .status != null and
    .priority != null and
    has("sprint_id") and
    has("implementer_id") and
    (.design_doc_paths | type == "array") and
    has("review_doc_path") and
    (.depends_on_pbi_ids | type == "array") and
    (.ux_change | type == "boolean") and
    has("parent_pbi_id") and
    .created_at != null and
    .updated_at != null
  )' "$file"
  assert_success
}

@test "PBI id matches pattern pbi-NNN" {
  local file="$FIXTURES_DIR/valid-backlog.json"

  # Every PBI id must match pbi- followed by one or more digits
  run jq -e '
    [.items[].id] | all(test("^pbi-[0-9]+$"))
  ' "$file"
  assert_success
}

@test "PBI status in fixture is one of the 12 unified status values" {
  local file="$FIXTURES_DIR/valid-backlog.json"

  # Every PBI status must be one of the 12 unified enum values.
  run jq -e '
    [.items[].status] | all(. as $s |
      ["draft","refined","blocked",
       "in_progress_design","in_progress_impl","in_progress_pbi_review",
       "in_progress_ut_run","in_progress_merge",
       "awaiting_cross_review","cross_review",
       "escalated","done"] | index($s) != null)
  ' "$file"
  assert_success
}

@test "12-value status enum covers all SM and Developer managed states" {
  # Sanity check that the canonical 12-value enum has exactly the SM (7) +
  # Developer (5) split documented in the plan.
  run bash -c '
    cat <<EOF | jq -e "length == 12"
[
  "draft","refined","blocked",
  "in_progress_design","in_progress_impl","in_progress_pbi_review",
  "in_progress_ut_run","in_progress_merge",
  "awaiting_cross_review","cross_review",
  "escalated","done"
]
EOF
'
  assert_success
}

@test "legacy PBI status values are no longer accepted" {
  # Old 6-value enum values must NOT appear in the 12-value canonical list.
  for legacy in "in_progress" "review"; do
    run jq -en --arg s "$legacy" '
      ["draft","refined","blocked",
       "in_progress_design","in_progress_impl","in_progress_pbi_review",
       "in_progress_ut_run","in_progress_merge",
       "awaiting_cross_review","cross_review",
       "escalated","done"] | index($s) == null
    '
    assert_success
  done
}

# ---------------------------------------------------------------------------
# sprint.json
# ---------------------------------------------------------------------------

@test "valid sprint has required fields" {
  local file="$FIXTURES_DIR/valid-sprint.json"

  run jq -e '.id' "$file"
  assert_success

  run jq -e '.goal' "$file"
  assert_success

  run jq -e '.type' "$file"
  assert_success

  run jq -e '.status' "$file"
  assert_success

  # OD-4 (2026-06): pbi_ids / developer_count removed — Sprint PBI membership
  # is derived from backlog.items[].sprint_id; developer count is
  # `developers | length`.
  run jq -e '.pbi_ids' "$file"
  assert_failure  # field must NOT be present in the canonical fixture

  run jq -e '.developer_count' "$file"
  assert_failure

  run jq -e '.developers | type == "array"' "$file"
  assert_success
}

@test "Developer has assigned_work with implement" {
  local file="$FIXTURES_DIR/valid-sprint.json"

  run jq -e '
    .developers[0] |
    (.assigned_work.implement | type == "array")
  ' "$file"
  assert_success
}

# ---------------------------------------------------------------------------
# improvements.json
# ---------------------------------------------------------------------------

@test "valid improvements has entries array" {
  local file="$FIXTURES_DIR/valid-improvements.json"

  run jq -e '.entries | type == "array"' "$file"
  assert_success
}
