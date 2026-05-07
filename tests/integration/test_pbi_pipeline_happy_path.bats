#!/usr/bin/env bats
# Integration: single PBI completes successfully in 1 design Round + 1 impl Round.
# Sub-agents are not actually spawned (this test exercises Developer-side
# orchestration logic, file plumbing, status transitions, and gate evaluation
# only). Real sub-agent invocation is covered by manual smoke test.

setup() {
  TEST_TMP="$(mktemp -d /tmp/claude/pbi-happy-test.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/pbi-happy-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1

  # Minimum viable .scrum layout
  mkdir -p .scrum docs/design/specs hooks/lib scripts/lib
  cp -r "${BATS_TEST_DIRNAME}/../../hooks/lib/"* hooks/lib/
  cp -r "${BATS_TEST_DIRNAME}/../../scripts/lib/"* scripts/lib/
  cp "${BATS_TEST_DIRNAME}/../fixtures/fake-codex.sh" .
  chmod +x fake-codex.sh

  cat > .scrum/config.json <<'EOF'
{
  "test_runner": {"command": "true", "args": []},
  "coverage_tool": null,
  "pragma_pattern": "pragma: no cover",
  "path_guard": {"impl_globs": ["src/**"], "test_globs": ["tests/**"]}
}
EOF

  cat > .scrum/state.json <<'EOF'
{ "phase": "pbi_pipeline_active",
  "current_sprint": "sprint-001" }
EOF

  cat > .scrum/sprint.json <<'EOF'
{ "id": "sprint-001",
  "status": "active",
  "started_at": "2026-05-07T00:00:00Z",
  "developers": [
    { "id": "dev-001-s1",
      "assigned_work": {"implement": ["pbi-001"]},
      "current_pbi": "pbi-001",
      "status": "active",
      "sub_agents": [] }
  ]
}
EOF

  cat > .scrum/backlog.json <<'EOF'
{ "items": [
  { "id": "pbi-001", "title": "test PBI", "status": "in_progress_design",
    "design_doc_paths": [], "review_doc_path": null,
    "catalog_targets": [],
    "pipeline_summary": null }
]}
EOF

  echo "# requirements" > .scrum/requirements.md

  export CODEX_CMD_OVERRIDE="$PWD/fake-codex.sh"
  export FAKE_CODEX_VERDICT="PASS"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Helper: set backlog PBI status without going through the wrapper script
# (the wrapper requires a full project layout we don't reconstruct here).
set_backlog_status() {
  local pbi_id="$1" new_status="$2"
  jq --arg id "$pbi_id" --arg s "$new_status" \
     '(.items[] | select(.id == $id)).status = $s' \
     .scrum/backlog.json > .scrum/backlog.json.tmp
  mv .scrum/backlog.json.tmp .scrum/backlog.json
}

@test "pipeline initializes PBI directory and state" {
  PBI_ID=pbi-001
  PBI_DIR=".scrum/pbi/$PBI_ID"
  mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}
  jq -n --arg id "$PBI_ID" --arg now "$(date -Iseconds)" '{
    pbi_id: $id,
    design_round: 0, impl_round: 0,
    design_status: "pending", impl_status: "pending",
    ut_status: "pending", coverage_status: "pending",
    escalation_reason: null,
    started_at: $now, updated_at: $now
  }' > "$PBI_DIR/state.json"

  [ -d "$PBI_DIR/design" ]
  [ -d "$PBI_DIR/metrics" ]
  jq -e '.design_status == "pending"' "$PBI_DIR/state.json"
  jq -e '.items[0].status == "in_progress_design"' .scrum/backlog.json
}

@test "design Round 1 success transitions to in_progress_impl" {
  PBI_ID=pbi-001
  PBI_DIR=".scrum/pbi/$PBI_ID"
  mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}

  # Simulate pbi-designer output
  echo "# Design for $PBI_ID" > "$PBI_DIR/design/design.md"

  # Simulate codex-design-reviewer via fake-codex
  source scripts/lib/codex-invoke.sh
  echo "stub instructions" > "$TEST_TMP/instr.md"
  codex_review_or_fallback "$TEST_TMP/instr.md" "$PBI_DIR/design/review-r1.md"

  # Verdict from review file
  grep -q '\*\*Verdict: PASS\*\*' "$PBI_DIR/design/review-r1.md"

  # Conductor would update both state.json and backlog.json on PASS
  jq -n --arg id "$PBI_ID" --arg now "$(date -Iseconds)" '{
    pbi_id: $id,
    design_round: 1, impl_round: 0,
    design_status: "pass", impl_status: "pending",
    ut_status: "pending", coverage_status: "pending",
    escalation_reason: null,
    started_at: $now, updated_at: $now
  }' > "$PBI_DIR/state.json"
  set_backlog_status "$PBI_ID" "in_progress_impl"

  jq -e '.design_status == "pass"' "$PBI_DIR/state.json"
  jq -e '.items[0].status == "in_progress_impl"' .scrum/backlog.json
  rm -f "$TEST_TMP/instr.md"
}

@test "impl+UT cycle Round 1 success transitions to in_progress_merge" {
  PBI_ID=pbi-001
  PBI_DIR=".scrum/pbi/$PBI_ID"
  mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}

  jq -n --arg id "$PBI_ID" --arg now "$(date -Iseconds)" '{
    pbi_id: $id,
    design_round: 1, impl_round: 1,
    design_status: "pass", impl_status: "in_review",
    ut_status: "in_review", coverage_status: "pending",
    escalation_reason: null,
    started_at: $now, updated_at: $now
  }' > "$PBI_DIR/state.json"
  set_backlog_status "$PBI_ID" "in_progress_pbi_review"

  source scripts/lib/codex-invoke.sh
  echo "stub" > "$TEST_TMP/instr.md"
  codex_review_or_fallback "$TEST_TMP/instr.md" "$PBI_DIR/impl/review-r1.md"
  codex_review_or_fallback "$TEST_TMP/instr.md" "$PBI_DIR/ut/review-r1.md"

  cat > "$PBI_DIR/metrics/test-results-r1.json" <<'EOF'
{ "round": 1, "pbi_id": "pbi-001", "tool": "stub",
  "tool_version": "0", "executed_at": "now",
  "totals": { "tests": 1, "passed": 1, "failed": 0,
              "exec_errors": 0, "uncaught_exceptions": 0, "skipped": 0 },
  "failures": [] }
EOF
  cat > "$PBI_DIR/metrics/coverage-r1.json" <<'EOF'
{ "round": 1, "pbi_id": "pbi-001", "tool": "stub",
  "tool_version": "0", "measured_at": "now",
  "totals": { "c0": {"covered": 10, "total": 10, "percent": 100.0},
              "c1": {"covered": 5, "total": 5, "percent": 100.0,
                     "supported": true} },
  "files": [] }
EOF
  cat > "$PBI_DIR/metrics/pragma-audit-r1.json" <<'EOF'
{ "round": 1, "pbi_id": "pbi-001", "audited_at": "now",
  "exclusions": [] }
EOF

  failed=$(jq '.totals.failed' "$PBI_DIR/metrics/test-results-r1.json")
  c0=$(jq '.totals.c0.percent' "$PBI_DIR/metrics/coverage-r1.json")
  c1=$(jq '.totals.c1.percent' "$PBI_DIR/metrics/coverage-r1.json")
  [ "$failed" -eq 0 ]
  awk "BEGIN{exit !($c0 >= 100)}"
  awk "BEGIN{exit !($c1 >= 100)}"

  # Conductor advances through pbi_review → ut_run → merge as each gate passes.
  set_backlog_status "$PBI_ID" "in_progress_ut_run"
  jq '.impl_status = "pass"' "$PBI_DIR/state.json" > "$PBI_DIR/state.json.tmp"
  mv "$PBI_DIR/state.json.tmp" "$PBI_DIR/state.json"

  set_backlog_status "$PBI_ID" "in_progress_merge"
  jq '.ut_status = "pass" | .coverage_status = "pass"' "$PBI_DIR/state.json" > "$PBI_DIR/state.json.tmp"
  mv "$PBI_DIR/state.json.tmp" "$PBI_DIR/state.json"

  jq -e '.impl_status == "pass" and .ut_status == "pass" and .coverage_status == "pass"' "$PBI_DIR/state.json"
  jq -e '.items[0].status == "in_progress_merge"' .scrum/backlog.json
  rm -f "$TEST_TMP/instr.md"
}
