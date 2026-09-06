#!/usr/bin/env bats

load '../test_helper/common-setup'

setup() {
  setup_temp_dir
  mkdir -p "$TEMP_DIR/.scrum"
  cd "$TEMP_DIR"
}

teardown() {
  teardown_temp_dir
}

run_statusline() {
  run bash "$PROJECT_ROOT/scripts/statusline.sh" <<< '{"model":{"display_name":"test"}}'
}

@test "PBI Development shows every Developer and backlog SSOT progress" {
  cat > .scrum/state.json <<'JSON'
{"phase":"pbi_pipeline_active","current_sprint_id":"sprint-1"}
JSON
  cat > .scrum/sprint.json <<'JSON'
{
  "id":"sprint-1",
  "goal":"Ship both PBIs",
  "developers":[
    {"id":"dev-001-s1","status":"active","current_pbi":"pbi-001","assigned_work":{"implement":["pbi-001"]}},
    {"id":"dev-002-s1","status":"failed","current_pbi":null,"assigned_work":{"implement":["pbi-002","pbi-003"]}},
    {"id":"dev-003-s1","status":"active"}
  ]
}
JSON
  cat > .scrum/backlog.json <<'JSON'
{
  "items":[
    {"id":"pbi-001","sprint_id":"sprint-1","status":"in_progress_impl"},
    {"id":"pbi-002","sprint_id":"sprint-1","status":"refined"},
    {"id":"pbi-003","sprint_id":"sprint-1","status":"done"}
  ]
}
JSON

  run_statusline

  assert_success
  [[ "$output" == *"Phase: PBI Development [pbi_pipeline_active]"* ]]
  [[ "$output" == *"Developer dev-001-s1 | status:active | current:pbi-001 | assigned:pbi-001 | progress:pbi-001=in_progress_impl"* ]]
  [[ "$output" == *"Developer dev-002-s1 | status:failed | current:none | assigned:pbi-002,pbi-003 | progress:pbi-002=refined,pbi-003=done"* ]]
  [[ "$output" == *"Developer dev-003-s1 | status:active | current:none | assigned:none | progress:unassigned"* ]]
  [[ "$output" != *"Scrum Master |"* ]]
}

@test "non-PBI phase in human mode shows Scrum Master only" {
  cat > .scrum/state.json <<'JSON'
{"phase":"sprint_planning","current_sprint_id":null}
JSON
  cat > .scrum/config.json <<'JSON'
{"po_mode":"human"}
JSON

  run_statusline

  assert_success
  [[ "$output" == *"Scrum Master | phase:Sprint Planning [sprint_planning]"* ]]
  [[ "$output" != *"Product Owner |"* ]]
  [[ "$output" != *"Developer "* ]]
}

@test "non-PBI phase in agent mode shows Scrum Master and Product Owner" {
  cat > .scrum/state.json <<'JSON'
{"phase":"sprint_review","current_sprint_id":"sprint-1"}
JSON
  cat > .scrum/config.json <<'JSON'
{"po_mode":"agent"}
JSON

  run_statusline

  assert_success
  [[ "$output" == *"Scrum Master | phase:Sprint Review [sprint_review]"* ]]
  [[ "$output" == *"Product Owner | mode:agent | phase:Sprint Review [sprint_review]"* ]]
}

@test "missing and invalid Scrum data degrades without failing" {
  printf '%s\n' '{not-json' > .scrum/state.json
  printf '%s\n' '{not-json' > .scrum/backlog.json
  printf '%s\n' '{not-json' > .scrum/sprint.json
  printf '%s\n' '{not-json' > .scrum/config.json

  run_statusline

  assert_success
  [[ "$output" == *"No active Sprint | Phase: unknown [unknown]"* ]]
  [[ "$output" == *"Backlog: unavailable (invalid JSON)"* ]]
  [[ "$output" == *"Scrum Master | phase:unknown [unknown]"* ]]
  [[ "$output" != *"Product Owner |"* ]]
}

@test "non-object JSON values degrade without failing" {
  printf '%s\n' '[]' > .scrum/state.json
  printf '%s\n' '[]' > .scrum/backlog.json
  printf '%s\n' '"not-an-object"' > .scrum/sprint.json
  printf '%s\n' '[]' > .scrum/config.json

  run_statusline

  assert_success
  [[ "$output" == *"No active Sprint | Phase: unknown [unknown]"* ]]
  [[ "$output" == *"Backlog: unavailable (invalid JSON)"* ]]
  [[ "$output" == *"Scrum Master | phase:unknown [unknown]"* ]]
  [[ "$output" != *"Product Owner |"* ]]
}

@test "PBI Development with an empty Developer array is explicit" {
  cat > .scrum/state.json <<'JSON'
{"phase":"pbi_pipeline_active","current_sprint_id":"sprint-1"}
JSON
  cat > .scrum/sprint.json <<'JSON'
{"id":"sprint-1","goal":"Waiting for assignment","developers":[]}
JSON

  run_statusline

  assert_success
  [[ "$output" == *"Developers | none assigned"* ]]
}
