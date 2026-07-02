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
  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"SessionStart"}'
  assert_success

  # Output must be valid JSON
  echo "$output" | jq empty
  [ $? -eq 0 ]

  # Context is nested under hookSpecificOutput so Claude Code honours it.
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
  local ctx
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [ -n "$ctx" ]
  [[ "$ctx" == *"New project"* ]]
}

@test "session-context.sh outputs phase context for existing project" {
  # Set up a .scrum/state.json with pbi_pipeline_active phase
  mkdir -p .scrum
  cp "$FIXTURES_DIR/hook-state-design.json" .scrum/state.json

  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"SessionStart"}'
  assert_success

  # Output must be valid JSON
  echo "$output" | jq empty
  [ $? -eq 0 ]

  # additionalContext must mention the phase
  local ctx
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"pbi_pipeline_active"* ]]
}

@test "session-context.sh: PostCompact event name is passed through" {
  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"PostCompact"}'
  assert_success
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostCompact" ]
  [ -n "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')" ]
}

@test "session-context.sh: defaults hookEventName to SessionStart when payload absent" {
  run bash "$PROJECT_ROOT/hooks/session-context.sh" < /dev/null
  assert_success
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
}

@test "session-context.sh: human mode emits no AUTONOMOUS PO MODE prologue" {
  mkdir -p .scrum
  jq -n '{"phase": "backlog_created", "current_sprint_id": "sprint-001", "product_goal": "g", "created_at": "2026-06-12T00:00:00Z", "updated_at": "2026-06-12T00:00:00Z"}' > .scrum/state.json
  echo '{"po_mode": "human"}' > .scrum/config.json
  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"SessionStart"}'
  assert_success
  local ctx
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" != *"AUTONOMOUS PO MODE"* ]]
}

@test "session-context.sh: agent mode emits AUTONOMOUS PO MODE prologue + iteration line" {
  mkdir -p .scrum
  jq -n '{"phase": "backlog_created", "current_sprint_id": "sprint-001", "product_goal": "g", "created_at": "2026-06-12T00:00:00Z", "updated_at": "2026-06-12T00:00:00Z"}' > .scrum/state.json
  cat > .scrum/config.json <<'EOF'
{"po_mode": "agent", "autonomous": {"max_iterations": 50}}
EOF
  cat > .scrum/autonomy.json <<'EOF'
{
  "run_id": "run-1",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": "sess-lead",
  "iteration": 3,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "idle", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null
}
EOF
  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"SessionStart"}'
  assert_success
  local ctx
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"AUTONOMOUS PO MODE"* ]]
  [[ "$ctx" == *"product-owner teammate"* ]]
  [[ "$ctx" == *"Teammate Liveness Protocol"* ]]
  [[ "$ctx" == *"iteration 3 of 50"* ]]
}

@test "session-context.sh: agent mode on brand-new project also gets prologue" {
  mkdir -p .scrum
  echo '{"po_mode": "agent"}' > .scrum/config.json
  cat > .scrum/autonomy.json <<'EOF'
{
  "run_id": "run-1",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": "sess-lead",
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "idle", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null
}
EOF
  # No state.json — exercises the "new project" branch.
  run bash "$PROJECT_ROOT/hooks/session-context.sh" <<< '{"hook_event_name":"SessionStart"}'
  assert_success
  local ctx
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"AUTONOMOUS PO MODE"* ]]
  [[ "$ctx" == *"New project"* ]]
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

  # File changes are work events only — no communications mirror
  [ ! -f ".scrum/communications.json" ]
}

@test "dashboard-event.sh handles MultiEdit like Write/Edit (DH-F4)" {
  mkdir -p .scrum

  # PostToolUse matcher includes MultiEdit; the inner tool_name case must
  # route it through the same file_changed branch as Write/Edit.
  local event_json
  event_json='{"hook_type":"PostToolUse","agent_id":"dev-001","tool_name":"MultiEdit","tool_input":{"file_path":"src/main.py"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  [ -f ".scrum/dashboard.json" ]
  jq -e '.events[-1].type == "file_changed"' .scrum/dashboard.json
  jq -e '.events[-1].file_path == "src/main.py"' .scrum/dashboard.json
  jq -e '.events[-1].change_type == "modified"' .scrum/dashboard.json
  jq -e '.events[-1].detail == "MultiEdit on src/main.py"' .scrum/dashboard.json
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

  # TeammateIdle is a message only — no dashboard.json work event mirror
  [ ! -f ".scrum/dashboard.json" ]
}

@test "dashboard-event.sh captures SendMessage as a comms message" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"PostToolUse","agent_id":"dev-001","tool_name":"SendMessage","tool_input":{"to":"scrum-master","summary":"PBI ready to merge","message":"[pbi-003] PBI_READY_TO_MERGE"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  [ -f ".scrum/communications.json" ]
  jq -e '.messages[-1].type == "message"' .scrum/communications.json
  jq -e '.messages[-1].sender_id == "dev-001"' .scrum/communications.json
  jq -e '.messages[-1].recipient_id == "scrum-master"' .scrum/communications.json
  jq -e '.messages[-1].content == "PBI ready to merge"' .scrum/communications.json

  # Messages do not generate dashboard.json work events
  [ ! -f ".scrum/dashboard.json" ]
}

@test "dashboard-event.sh SendMessage falls back to message body without summary" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"PostToolUse","agent_id":"dev-001","tool_name":"SendMessage","tool_input":{"to":"product-owner","message":"[pbi-003] PO_DECISION_REQUEST: accept scope cut?"}}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  jq -e '.messages[-1].content == "[pbi-003] PO_DECISION_REQUEST: accept scope cut?"' .scrum/communications.json
  jq -e '.messages[-1].recipient_id == "product-owner"' .scrum/communications.json
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

  # Lifecycle is a work event only — no communications mirror
  [ ! -f ".scrum/communications.json" ]
}

@test "dashboard-event.sh uses agent_type as the friendly name for subagent events" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"SubagentStart","agent_id":"a8733575f4dde12fa","agent_type":"code-reviewer"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  # The work event names the agent, not the opaque id
  jq -e '.events[-1].agent_id == "code-reviewer"' .scrum/dashboard.json
  jq -e '.events[-1].detail == "started work"' .scrum/dashboard.json

  # The id → name mapping is persisted (shortened to 8 hex chars)
  jq -e '.["a8733575"] == "code-reviewer"' .scrum/session-map.json
}

@test "dashboard-event.sh resolves Stop event to a previously mapped name" {
  mkdir -p .scrum

  # SubagentStart saves the mapping ...
  run bash -c "echo '{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"a8733575f4dde12fa\",\"agent_type\":\"dev-001-s1\"}' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  # ... and a later Stop event carrying only the id resolves to the name
  run bash -c "echo '{\"hook_event_name\":\"Stop\",\"session_id\":\"a8733575f4dde12fa\",\"reason\":\"completed\"}' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  jq -e '.events[-1].agent_id == "dev-001-s1"' .scrum/dashboard.json
  jq -e '.events[-1].detail == "session stopped (completed)"' .scrum/dashboard.json
}

@test "dashboard-event.sh shortens long hex agent ids without a name mapping" {
  mkdir -p .scrum

  local event_json
  event_json='{"hook_event_name":"SubagentStop","agent_id":"a8733575f4dde12fa"}'

  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/dashboard-event.sh'"
  assert_success

  jq -e '.events[-1].agent_id == "a8733575"' .scrum/dashboard.json
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

@test "status-gate.sh denies source MultiEdit during sprint_planning" {
  mkdir -p .scrum
  jq -n '{"phase": "sprint_planning", "current_sprint_id": "sprint-001"}' > .scrum/state.json

  local event_json
  event_json='{"tool_name":"MultiEdit","tool_input":{"file_path":"src/main.py"}}'

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

@test "setup-user.sh settings.json template includes MultiEdit in status-gate matcher" {
  run grep -q '"matcher": "Write|Edit|MultiEdit"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
}

@test "setup-user.sh settings.json template excludes Bash from dashboard-event matcher" {
  run grep -q '"matcher": "Write|Edit|MultiEdit|Agent|SendMessage"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
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

@test "completion-gate.sh allows stop when active PBI pipeline non-terminal (human mode, in-flight only)" {
  # Block-noise reduction: in human mode (no .scrum/config.json or
  # po_mode != "agent"), in-flight PBIs alone no longer block Stop.
  # External watchdog (scripts/stall-watchdog.sh) handles teammate
  # liveness. Only escalated PBIs without resolution still block —
  # covered by the "lists escalated PBI ids" test below.
  mkdir -p .scrum
  cp "$FIXTURES_DIR/valid-state.json" .scrum/state.json  # phase=pbi_pipeline_active
  cp "$FIXTURES_DIR/valid-sprint.json" .scrum/sprint.json
  jq '.items[0].status = "in_progress_design"' "$FIXTURES_DIR/valid-backlog.json" > .scrum/backlog.json

  run bash "$PROJECT_ROOT/hooks/completion-gate.sh"
  assert_success
}

@test "completion-gate.sh emits compressed status-grouped count for pbi_pipeline_active under autonomy" {
  # Behaviour preserved under autonomy mode: the inner-loop watchdog
  # contract still relies on the verbose block while teammates are
  # in-flight. Human mode dropped this gate to reduce context noise
  # (covered in the human-mode test above).
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
  # Enable autonomy so the historical block fires.
  echo '{"po_mode": "agent"}' > .scrum/config.json
  cat > .scrum/autonomy.json <<'EOF'
{
  "run_id": "run-1",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": "sess-lead",
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "idle", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null
}
EOF
  # A live watchdog must appear to be driving the loop for the autonomous
  # block to fire (BUG-3: the gate degrades to human mode when no live
  # watchdog_pid is present). Use this test process's pid — it is alive.
  jq --argjson pid "$$" '.watchdog_pid = $pid' .scrum/autonomy.json > .scrum/autonomy.json.tmp \
    && mv .scrum/autonomy.json.tmp .scrum/autonomy.json

  run bash -c "printf '%s' '{\"session_id\":\"sess-lead\",\"hook_event_name\":\"Stop\"}' | bash $PROJECT_ROOT/hooks/completion-gate.sh"
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

@test "stop-failure.sh: agent mode records last_failure on autonomy.json" {
  mkdir -p .scrum
  echo '{"po_mode": "agent"}' > .scrum/config.json
  cat > .scrum/autonomy.json <<'EOF'
{
  "run_id": "run-1",
  "started_at": "2026-06-12T00:00:00Z",
  "lead_session_id": "sess-lead",
  "iteration": 0,
  "total_cost_usd": 0,
  "stop_blocks": {"phase": "idle", "count": 0},
  "circuit_breaker_tripped": null,
  "last_failure": null
}
EOF
  local event_json='{"hook_event_name":"StopFailure","reason":"rate_limit","agent_id":"scrum-master"}'
  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/stop-failure.sh'"
  assert_success
  run jq -r '.last_failure.reason' .scrum/autonomy.json
  [ "$output" = "rate_limit" ]
  run jq -r '.last_failure.at' .scrum/autonomy.json
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "stop-failure.sh: human mode does NOT touch autonomy.json (fail-open / no-op)" {
  mkdir -p .scrum
  echo '{"po_mode": "human"}' > .scrum/config.json
  # autonomy.json deliberately absent — autonomy_enabled returns false.
  local event_json='{"hook_event_name":"StopFailure","reason":"rate_limit","agent_id":"scrum-master"}'
  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/stop-failure.sh'"
  assert_success
  [ ! -f ".scrum/autonomy.json" ]
}

@test "stop-failure.sh: agent mode without autonomy.json is a silent no-op (fail-open)" {
  mkdir -p .scrum
  echo '{"po_mode": "agent"}' > .scrum/config.json
  # autonomy.json missing → autonomy_enabled returns false → no write attempt.
  local event_json='{"hook_event_name":"StopFailure","reason":"timeout","agent_id":"sm"}'
  run bash -c "echo '$event_json' | bash '$PROJECT_ROOT/hooks/stop-failure.sh'"
  assert_success
  [ ! -f ".scrum/autonomy.json" ]
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

@test "setup-user.sh settings.json template includes Write|Edit|MultiEdit matcher for PreToolUse" {
  # Validate the heredoc template source directly — no prereqs required
  run grep -A1 '"PreToolUse"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
  # The matcher line must appear somewhere after PreToolUse in the file
  run grep '"matcher": "Write|Edit|MultiEdit"' "$PROJECT_ROOT/scripts/setup-user.sh"
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

@test "setup-user.sh settings.json template registers only stop-failure.sh for StopFailure (RC#9: dashboard-event.sh had no StopFailure branch, was a no-op)" {
  run awk '/"StopFailure": \[/,/^    \]/' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_success
  [[ "$output" == *"stop-failure.sh"* ]]
  [[ "$output" != *"dashboard-event.sh"* ]]
}

@test "setup-user.sh settings.json template excludes the dead FileChanged registration (T1-3: no matcher/watchPaths means the watcher never starts)" {
  run grep -q '"FileChanged"' "$PROJECT_ROOT/scripts/setup-user.sh"
  assert_failure
}
