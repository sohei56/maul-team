#!/usr/bin/env bats
# escalation-smoke.bats — Smoke test for escalation status transitions.
#
# Verifies that, given the 12-value status enum (PBI-A) and the expanded
# escalation_reason enum (PBI-A), three canonical escalation transitions
# produce schema-valid state.
#
# Scope: status / escalation_reason mutation only — wrapper scripts
# (update-backlog-status.sh etc.) are intentionally NOT invoked here so
# this test is independent of PBI-B's parallel work. State files are
# mutated directly via jq and then validated against the SSOT schemas
# in docs/contracts/scrum-state/.
#
# Scenarios:
#   1. Stagnation     : in_progress_impl  -> escalated (reason=stagnation)
#   2. Max rounds     : in_progress_impl  -> escalated (reason=max_rounds)
#   3. Merge failure  : in_progress_merge -> escalated (reason=merge_conflict)

load '../test_helper/common-setup'

setup() {
  setup_temp_dir
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  BACKLOG_SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json"
  PBI_STATE_SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json"
  export BACKLOG_SCHEMA PBI_STATE_SCHEMA
  cd "$TEMP_DIR"
  mkdir -p .scrum/pbi/pbi-001
  seed_state
}

teardown() {
  teardown_temp_dir
}

# Seed an in-flight PBI: backlog status=in_progress_impl, pbi-state with
# round counters and null escalation_reason.
seed_state() {
  cat > .scrum/backlog.json <<'EOF'
{
  "product_goal": "Escalation smoke test",
  "items": [
    {
      "id": "pbi-001",
      "title": "PBI under escalation test",
      "status": "in_progress_impl",
      "priority": 1,
      "sprint_id": "sprint-001",
      "implementer_id": "dev-001-s1",
      "design_doc_paths": [],
      "review_doc_path": null,
      "depends_on_pbi_ids": [],
      "ux_change": false,
      "parent_pbi_id": null,
      "created_at": "2026-05-06T10:00:00Z",
      "updated_at": "2026-05-06T10:00:00Z"
    }
  ],
  "next_pbi_id": 2
}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{
  "pbi_id": "pbi-001",
  "design_round": 1,
  "impl_round": 1,
  "design_status": "pass",
  "impl_status": "fail",
  "ut_status": "pending",
  "coverage_status": "pending",
  "escalation_reason": null,
  "started_at": "2026-05-06T10:00:00Z",
  "updated_at": "2026-05-06T10:00:00Z"
}
EOF
}

# Mutate backlog status for pbi-001 in place. Uses an in-tree temp file so
# the test stays inside the sandbox-allowed working directory (mktemp's
# default /var/... location is blocked).
set_backlog_status() {
  local new_status="$1"
  local tmp=".scrum/.tmp.backlog.$$"
  jq --arg s "$new_status" \
     '(.items[] | select(.id=="pbi-001").status) = $s
      | (.items[] | select(.id=="pbi-001").updated_at) = "2026-05-06T11:00:00Z"' \
     .scrum/backlog.json > "$tmp"
  mv "$tmp" .scrum/backlog.json
}

# Mutate pbi-state escalation_reason in place. Pass keys/vals as flat pairs.
# Usage: set_pbi_state escalation_reason stagnation impl_round 5
set_pbi_state() {
  local file=.scrum/pbi/pbi-001/state.json
  local tmp=".scrum/.tmp.pbi-state.$$"
  local filter='.updated_at = "2026-05-06T11:00:00Z"'
  while [ "$#" -ge 2 ]; do
    local key="$1" val="$2"
    shift 2
    case "$key" in
      impl_round|design_round|merge_failure_count)
        filter="$filter | .${key} = ${val}"
        ;;
      merge_failure_kind)
        # build a nested object literal for merge_failure
        filter="$filter | .merge_failure = {\"kind\": \"${val}\", \"pre_head_at_failure\": \"abc1234\"}"
        ;;
      *)
        filter="$filter | .${key} = \"${val}\""
        ;;
    esac
  done
  jq "$filter" "$file" > "$tmp"
  mv "$tmp" "$file"
}

assert_schema_valid() {
  local instance="$1" schema="$2"
  run jsonschema --instance "$instance" "$schema"
  if [ "$status" -ne 0 ]; then
    echo "Schema validation failed for: $instance"
    echo "Schema: $schema"
    echo "Output: $output"
    return 1
  fi
}

assert_backlog_status() {
  local expected="$1"
  local actual
  actual="$(jq -r '.items[] | select(.id=="pbi-001").status' .scrum/backlog.json)"
  [ "$actual" = "$expected" ] || {
    echo "backlog status mismatch: expected=$expected actual=$actual"
    return 1
  }
}

assert_pbi_state_field() {
  local jq_expr="$1" expected="$2"
  local actual
  actual="$(jq -r "$jq_expr" .scrum/pbi/pbi-001/state.json)"
  [ "$actual" = "$expected" ] || {
    echo "pbi-state field mismatch: expr=$jq_expr expected=$expected actual=$actual"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Scenario 1: Stagnation
# ---------------------------------------------------------------------------

@test "stagnation: in_progress_impl -> escalated with escalation_reason=stagnation" {
  # Pre-condition: starting state seeded.
  assert_backlog_status "in_progress_impl"
  assert_pbi_state_field '.escalation_reason' "null"

  # Termination gate trips on stagnation: Developer marks PBI escalated
  # with reason=stagnation.
  set_pbi_state escalation_reason stagnation
  set_backlog_status escalated

  # Post-condition: schema-valid, status flipped, reason recorded.
  assert_schema_valid .scrum/backlog.json "$BACKLOG_SCHEMA"
  assert_schema_valid .scrum/pbi/pbi-001/state.json "$PBI_STATE_SCHEMA"
  assert_backlog_status "escalated"
  assert_pbi_state_field '.escalation_reason' "stagnation"
}

# ---------------------------------------------------------------------------
# Scenario 2: Max rounds
# ---------------------------------------------------------------------------

@test "max_rounds: in_progress_impl -> escalated with escalation_reason=max_rounds" {
  assert_backlog_status "in_progress_impl"

  # Hard cap reached: impl_round bumped to 5, reason set, status flipped.
  set_pbi_state impl_round 5 escalation_reason max_rounds
  set_backlog_status escalated

  assert_schema_valid .scrum/backlog.json "$BACKLOG_SCHEMA"
  assert_schema_valid .scrum/pbi/pbi-001/state.json "$PBI_STATE_SCHEMA"
  assert_backlog_status "escalated"
  assert_pbi_state_field '.escalation_reason' "max_rounds"
  assert_pbi_state_field '.impl_round' "5"
}

# ---------------------------------------------------------------------------
# Scenario 3: Merge failure
# ---------------------------------------------------------------------------

@test "merge_conflict: in_progress_merge -> escalated with escalation_reason=merge_conflict" {
  # Move PBI to in_progress_merge (Developer signaled ready for merge).
  set_backlog_status in_progress_merge
  assert_backlog_status "in_progress_merge"

  # SM merge attempt fails with conflict: SM records merge_failure.kind,
  # sets escalation_reason, flips status to escalated.
  set_pbi_state merge_failure_count 1 \
                merge_failure_kind conflict \
                escalation_reason merge_conflict
  set_backlog_status escalated

  assert_schema_valid .scrum/backlog.json "$BACKLOG_SCHEMA"
  assert_schema_valid .scrum/pbi/pbi-001/state.json "$PBI_STATE_SCHEMA"
  assert_backlog_status "escalated"
  assert_pbi_state_field '.escalation_reason' "merge_conflict"
  assert_pbi_state_field '.merge_failure.kind' "conflict"
  assert_pbi_state_field '.merge_failure_count' "1"
}
