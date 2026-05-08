#!/usr/bin/env bats
# hooks.bats — Tests each hook script with mock .scrum/ state files.

load '../test_helper/common-setup'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  setup_temp_dir
  # Hooks resolve paths relative to cwd, so we work inside TEMP_DIR
  cd "$TEMP_DIR"
}

teardown() {
  teardown_temp_dir
}

# ---------------------------------------------------------------------------
# session-context.sh
# ---------------------------------------------------------------------------

@test "session-context.sh outputs valid JSON for new project" {
  # No .scrum/ directory — brand-new project
  run bash "$PROJECT_ROOT/hooks/session-context.sh"
  assert_success

  # Output must be valid JSON
  echo "$output" | jq empty
  [ $? -eq 0 ]

  # Must contain additionalContext key
  local ctx
  ctx="$(echo "$output" | jq -r '.additionalContext')"
  [ -n "$ctx" ]
  [[ "$ctx" == *"New project"* ]]
}

@test "session-context.sh outputs phase context for existing project" {
  # Set up a .scrum/state.json with pbi_pipeline_active phase
  mkdir -p .scrum
  cp "$FIXTURES_DIR/hook-state-design.json" .scrum/state.json

  run bash "$PROJECT_ROOT/hooks/session-context.sh"
  assert_success

  # Output must be valid JSON
  echo "$output" | jq empty
  [ $? -eq 0 ]

  # additionalContext must mention the phase
  local ctx
  ctx="$(echo "$output" | jq -r '.additionalContext')"
  [[ "$ctx" == *"pbi_pipeline_active"* ]]
}

# ---------------------------------------------------------------------------
# dashboard-event.sh
# ---------------------------------------------------------------------------

@test "dashboard-event.sh creates dashboard.json if missing" {
  mkdir -p .scrum

  # Pipe a PostToolUse event with a Write tool into the hook
  local event_json
  event_json='{"hook_type":"PostToolUse","agent_id":"dev-001","tool_name":"Write","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  # dashboard.json must have been created
  [ -f ".scrum/dashboard.json" ]

  # It must be valid JSON with an events array
  jq -e '.events | type == "array"' .scrum/dashboard.json
}

@test "dashboard-event.sh creates communications.json if missing" {
  mkdir -p .scrum

  # Pipe a TeammateIdle event into the hook
  local event_json
  event_json='{"hook_type":"TeammateIdle","teammate_id":"dev-001","teammate_role":"Developer","message":"Waiting for review"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  # communications.json must have been created
  [ -f ".scrum/communications.json" ]

  # It must be valid JSON with a messages array
  jq -e '.messages | type == "array"' .scrum/communications.json
}

@test "dashboard-event.sh handles SubagentStart event" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"SubagentStart","agent_id":"abc12345-1234-5678-9abc-def012345678"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  # Event type should be subagent_start
  jq -e '.events[-1].type == "subagent_start"' .scrum/dashboard.json
}

@test "dashboard-event.sh handles SubagentStop event" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"SubagentStop","agent_id":"abc12345-1234-5678-9abc-def012345678"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  jq -e '.events[-1].type == "subagent_stop"' .scrum/dashboard.json

  # Should also create a communications message
  [ -f ".scrum/communications.json" ]
  jq -e '.messages[-1].type == "status_change"' .scrum/communications.json
}

@test "dashboard-event.sh handles TaskCompleted event" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"TaskCompleted","agent_id":"dev-001","tool_name":"test-runner"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  jq -e '.events[-1].type == "task_completed"' .scrum/dashboard.json
}

@test "dashboard-event.sh deduplicates comms messages" {
  mkdir -p .scrum

  # Send same TeammateIdle event twice
  local event_json
  event_json='{"hook_event_name":"TeammateIdle","teammate_name":"dev-001-s1","session_id":"abc12345","last_message":"waiting for task"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  # Should only have 1 message (second was deduplicated)
  local msg_count
  msg_count="$(jq '.messages | length' .scrum/communications.json)"
  [ "$msg_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# status-gate.sh
# ---------------------------------------------------------------------------

@test "status-gate.sh allows Edit during pbi_pipeline_active" {
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json  # phase=pbi_pipeline_active

  # Simulate an Edit tool event on a source file
  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  # Decision should be allow
  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "allow" ]
}

@test "status-gate.sh denies source Edit during requirements_sprint" {
  mkdir -p .scrum
  jq -n '{"phase": "requirements_sprint", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  # Simulate an Edit tool event on a source file
  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  # Decision should be deny
  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies source Edit during sprint_planning" {
  mkdir -p .scrum
  jq -n '{"phase": "sprint_planning", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies source Write during sprint_planning" {
  mkdir -p .scrum
  jq -n '{"phase": "sprint_planning", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"src/new_file.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies source Edit during retrospective" {
  mkdir -p .scrum
  jq -n '{"phase": "retrospective", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies Write to docs/design/catalog.md" {
  mkdir -p .scrum
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"docs/design/catalog.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies Edit to docs/design/catalog.md in any phase" {
  mkdir -p .scrum
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":"docs/design/catalog.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies design spec write when ID not in catalog-config.json" {
  mkdir -p .scrum docs/design
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json
  printf '| ID | Spec Name | Granularity |\n|---|---|---|\n| S-030 | Screen Design | One per screen |\n' > docs/design/catalog.md
  echo '{"enabled": ["S-001"]}' > docs/design/catalog-config.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"docs/design/specs/ui/S-030-screen-design.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh denies design spec write when ID not in catalog.md" {
  mkdir -p .scrum docs/design
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json
  printf '| ID | Spec Name | Granularity |\n|---|---|---|\n| S-001 | System Architecture | One per project |\n' > docs/design/catalog.md
  echo '{"enabled": ["S-030"]}' > docs/design/catalog-config.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"docs/design/specs/ui/S-030-screen-design.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "deny" ]
}

@test "status-gate.sh allows design spec write when ID in both catalog.md and config" {
  mkdir -p .scrum docs/design
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json
  printf '| ID | Spec Name | Granularity |\n|---|---|---|\n| S-030 | Screen Design | One per screen |\n' > docs/design/catalog.md
  echo '{"enabled": ["S-030"]}' > docs/design/catalog-config.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"docs/design/specs/ui/S-030-screen-design.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "allow" ]
}

@test "status-gate.sh enforces catalog in pbi_pipeline_active phase via Write" {
  mkdir -p .scrum docs/design
  echo '{"phase": "pbi_pipeline_active"}' > .scrum/state.json
  printf '| ID | Spec Name | Granularity |\n|---|---|---|\n| S-030 | Screen Design | One per screen |\n' > docs/design/catalog.md
  echo '{"enabled": ["S-030"]}' > docs/design/catalog-config.json

  local event_json
  event_json='{"tool_name":"Write","tool_input":{"file_path":"docs/design/specs/ui/S-030-screen-design.md"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "allow" ]
}

@test "status-gate.sh allows metadata file Edit during sprint_planning" {
  mkdir -p .scrum
  jq -n '{"phase": "sprint_planning", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  # Editing a .scrum/ JSON file should be allowed (not source code)
  local event_json
  event_json='{"tool_name":"Edit","tool_input":{"file_path":".scrum/backlog.json"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/status-gate.sh'"
  assert_success

  local decision
  decision="$(echo "$output" | jq -r '.decision')"
  [ "$decision" = "allow" ]
}

# ---------------------------------------------------------------------------
# completion-gate.sh
# ---------------------------------------------------------------------------

@test "completion-gate.sh allows stop when no state file exists" {
  # No .scrum/ directory at all
  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh allows stop in ungated phase" {
  mkdir -p .scrum
  # Create a state file with a phase that has no exit criteria
  jq -n '{"phase": "sprint_planning", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh blocks stop when active PBI pipeline non-terminal" {
  mkdir -p .scrum
  # Active pipelines are derived from backlog.json: any in_progress_* status.
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json  # phase=pbi_pipeline_active
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
}

@test "completion-gate.sh emits compressed status-grouped count for pbi_pipeline_active" {
  # Verify the block message is a status-grouped count (not per-PBI listing)
  # to keep context noise low when the hook fires on every SM turn-end.
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items = [
    {"id":"pbi-001","status":"in_progress_design","priority":1,"name":"a","description":"x","sized":true},
    {"id":"pbi-002","status":"in_progress_design","priority":2,"name":"b","description":"x","sized":true},
    {"id":"pbi-003","status":"in_progress_impl","priority":3,"name":"c","description":"x","sized":true},
    {"id":"pbi-004","status":"in_progress_merge","priority":4,"name":"d","description":"x","sized":true},
    {"id":"pbi-005","status":"done","priority":5,"name":"e","description":"x","sized":true}
  ]' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"3 in-flight"* ]]
  [[ "$output" == *"2 design"* ]]
  [[ "$output" == *"1 impl"* ]]
  # in_progress_merge (terminal Dev status) and done (terminal) are excluded
  [[ "$output" != *"merge"* ]]
  [[ "$output" != *"pbi-001"* ]]
  # Teammate guidance must be inlined: SubagentStart hook does not fire
  # for Agent-tool spawns, so in_flight_hint() is a no-op here.
  [[ "$output" == *"do NOT re-spawn"* ]]
  [[ "$output" == *"TaskGet"* ]]
  [[ "$output" == *"SendMessage"* ]]
}

@test "completion-gate.sh lists escalated PBI ids when resolution missing" {
  # Escalated PBIs are rare and require operator action; keep ID listing.
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "escalated" | .items[0].id = "pbi-007"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"escalated without resolution"* ]]
  [[ "$output" == *"pbi-007"* ]]
}

@test "completion-gate.sh allows stop when escalated PBI has resolution recorded" {
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "escalated" | .items[0].id = "pbi-007"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json
  mkdir -p .scrum/pbi/pbi-007
  echo "resolved" > .scrum/pbi/pbi-007/escalation-resolution.md

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh allows stop when active PBI pipeline terminal" {
  mkdir -p .scrum
  # pbi-001 reached awaiting_cross_review (terminal); not derived as active.
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "awaiting_cross_review"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh allows stop when active PBI pipeline in_progress_merge" {
  # in_progress_merge is the Developer-side terminal status: PBI is ready
  # for SM-side merge orchestration and the Developer's session may stop.
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_merge"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh allows stop when backlog absent in pbi_pipeline_active" {
  mkdir -p .scrum
  # phase=pbi_pipeline_active with no backlog.json — nothing to gate on
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json
  # Intentionally do NOT create sprint.json or backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh blocks stop when PBIs not done in review" {
  mkdir -p .scrum
  jq '.phase = "review"' "$FIXTURES_DIR/valid-state.json" > .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
}

@test "completion-gate.sh allows stop when all PBIs done in review" {
  mkdir -p .scrum
  jq '.phase = "review"' "$FIXTURES_DIR/valid-state.json" > .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "done"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh appends in-flight subagent hint to block reason" {
  mkdir -p .scrum
  jq '.phase = "review"' "$FIXTURES_DIR/valid-state.json" > .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "cross_review"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  # 2 subagents started, 1 stopped → 1 in-flight
  jq -n '{
    "events": [
      {"timestamp":"2026-01-01T00:00:00Z","type":"subagent_start","agent_id":"a1"},
      {"timestamp":"2026-01-01T00:00:01Z","type":"subagent_start","agent_id":"a2"},
      {"timestamp":"2026-01-01T00:00:30Z","type":"subagent_stop","agent_id":"a1"}
    ]
  }' > .scrum/dashboard.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"1 subagent(s) still running"* ]]
  [[ "$output" == *"do NOT re-spawn"* ]]
}

@test "completion-gate.sh omits hint when no in-flight subagents" {
  mkdir -p .scrum
  jq '.phase = "review"' "$FIXTURES_DIR/valid-state.json" > .scrum/state.json
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "cross_review"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  # All subagents stopped → 0 in-flight
  jq -n '{
    "events": [
      {"timestamp":"2026-01-01T00:00:00Z","type":"subagent_start","agent_id":"a1"},
      {"timestamp":"2026-01-01T00:00:30Z","type":"subagent_stop","agent_id":"a1"}
    ]
  }' > .scrum/dashboard.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" != *"subagent(s) still running"* ]]
}

# ---------------------------------------------------------------------------
# quality-gate.sh
# ---------------------------------------------------------------------------

@test "quality-gate.sh skips checks when no PBI ID in event" {
  mkdir -p .scrum

  local event_json='{"hook_type":"TaskCompleted"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/quality-gate.sh'"
  assert_success
}

@test "quality-gate.sh skips checks when no backlog exists" {
  mkdir -p .scrum

  local event_json='{"hook_type":"TaskCompleted","pbi_id":"pbi-001"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/quality-gate.sh'"
  assert_success
}

@test "quality-gate.sh runs DoD checks and always exits 0" {
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-backlog.json" .scrum/backlog.json

  local event_json='{"hook_type":"TaskCompleted","pbi_id":"pbi-001"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/quality-gate.sh'"
  assert_success
}

# ---------------------------------------------------------------------------
# stop-failure.sh
# ---------------------------------------------------------------------------

@test "stop-failure.sh logs rate_limit failure to dashboard.json" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"StopFailure","reason":"rate_limit","agent_id":"dev-001"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/stop-failure.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  jq -e '.events[-1].type == "stop_failure"' .scrum/dashboard.json
  jq -e '.events[-1].detail | test("rate_limit")' .scrum/dashboard.json
}

@test "stop-failure.sh logs authentication_failed to dashboard.json" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"StopFailure","reason":"authentication_failed","agent_id":"scrum-master"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/stop-failure.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  jq -e '.events[-1].type == "stop_failure"' .scrum/dashboard.json
}

# ---------------------------------------------------------------------------
# settings.json template validation
# ---------------------------------------------------------------------------

@test "setup-user.sh generates PreToolUse with Write|Edit matcher" {
  skip "requires full prerequisites (claude, python, textual, watchdog)"
  setup_temp_dir
  cd "$TEMP_DIR"
  git init --quiet
  mkdir -p .scrum

  run bash "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success

  # PreToolUse hook must have a matcher field
  run jq -r '.hooks.PreToolUse[0].matcher' .claude/settings.json
  assert_output "Write|Edit"
}

@test "setup-user.sh settings.json template includes Write|Edit matcher for PreToolUse" {
  # Validate the heredoc template source directly — no prereqs required
  run grep -A1 '"PreToolUse"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
  # The matcher line must appear somewhere after PreToolUse in the file
  run grep '"matcher": "Write|Edit"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
}

@test "setup-user.sh settings.json template includes PostCompact hook" {
  run grep -q '"PostCompact"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
  run grep -q 'session-context.sh' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
}

@test "setup-user.sh settings.json template includes StopFailure hook" {
  run grep -q '"StopFailure"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
  run grep -q 'stop-failure.sh' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
}

@test "setup-user.sh settings.json template includes FileChanged hook" {
  run grep -q '"FileChanged"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
}
