#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-rtm.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-rtm.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress_ut_run"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/src.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "first"
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-ready-to-merge: sets head_sha, paths_touched, ready_at on state.json" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.paths_touched | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.paths_touched[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = "src.txt" ]
  run jq -r '.head_sha' .scrum/pbi/pbi-001/state.json
  EXPECTED="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  [ "$output" = "$EXPECTED" ]
  run jq -r '.ready_at' .scrum/pbi/pbi-001/state.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "mark-ready-to-merge: backlog status flips to in_progress_merge" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
}

@test "mark-ready-to-merge: refuses if no commits diverge from base" {
  # Reset branch to base so diff is empty.
  WT=.scrum/worktrees/pbi-001
  git -C "$WT" reset --hard HEAD~1
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# kind=docs boundary enforce
# ---------------------------------------------------------------------------

# Helper: flip backlog item kind to docs and add a second commit touching
# only a .md file. Reuses the setup() PBI but layers docs commits on top.
_mark_kind_docs_pbi() {
  jq '(.items[] | select(.id == "pbi-001") | .kind) = "docs"' .scrum/backlog.json > tmp.json
  mv tmp.json .scrum/backlog.json
}

@test "mark-ready-to-merge: kind=docs + paths only .md -> success" {
  _mark_kind_docs_pbi
  WT=.scrum/worktrees/pbi-001
  # Replace the existing src.txt commit with a .md-only history.
  git -C "$WT" reset --hard HEAD~1
  echo "# title" > "$WT/notes.md"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "docs only"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
  run jq -r '.paths_touched[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = "notes.md" ]
}

@test "mark-ready-to-merge: kind=docs + non-.md path -> escalated(kind_mismatch)" {
  _mark_kind_docs_pbi
  # setup() already committed src.txt (non-.md) — exactly the violation case.
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "escalated" ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "kind_mismatch" ]
  # paths_touched / head_sha must NOT be set when the boundary fails.
  run jq -r 'has("paths_touched")' .scrum/pbi/pbi-001/state.json
  [ "$output" = "false" ]
}

@test "mark-ready-to-merge: kind=docs + mixed paths -> escalated(kind_mismatch)" {
  _mark_kind_docs_pbi
  WT=.scrum/worktrees/pbi-001
  # On top of setup()'s src.txt commit (non-.md), add a docs-only commit.
  echo "# title" > "$WT/notes.md"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "mixed"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "kind_mismatch" ]
}

@test "mark-ready-to-merge: kind=code + non-.md path -> success (boundary inactive)" {
  # Default kind from setup() is absent (treated as 'code'). setup() committed
  # src.txt which is non-.md — under kind=code this must merge cleanly.
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
}

# Helper: rebuild the pbi-001 branch so that a .sh file exists at base and is
# then DELETED (with a .md added so paths_touched/AMR is non-empty). Re-stamps
# state.base_sha to the commit that holds the .sh file. Echoes nothing.
_docs_pbi_with_deletion() {
  local extra_file="$1"   # file to delete alongside the .md addition
  _mark_kind_docs_pbi
  local WT=.scrum/worktrees/pbi-001
  git -C "$WT" reset --hard HEAD~1        # drop setup()'s src.txt commit → back to base
  printf 'echo hi\n' > "$WT/$extra_file"
  git -C "$WT" add "$extra_file"
  git -C "$WT" commit -q -m "add $extra_file"
  local newbase; newbase="$(git -C "$WT" rev-parse HEAD)"
  jq --arg b "$newbase" '.base_sha = $b' .scrum/pbi/pbi-001/state.json > tmp.json && mv tmp.json .scrum/pbi/pbi-001/state.json
  git -C "$WT" rm -q "$extra_file"
  echo "# notes" > "$WT/notes.md"
  git -C "$WT" add notes.md
  git -C "$WT" commit -q -m "delete $extra_file, add notes.md"
}

@test "mark-ready-to-merge: kind=docs DELETING a non-.md file -> escalated(kind_mismatch)" {
  # T1-9: paths_touched (AMR) excludes deletions, so a docs PBI that DELETES a
  # .sh file passed the boundary before this fix. The deletion must now be
  # inspected and rejected just like a non-.md addition.
  _docs_pbi_with_deletion foo.sh
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "escalated" ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "kind_mismatch" ]
  # paths_touched / head_sha must NOT be set when the boundary fails.
  run jq -r 'has("paths_touched")' .scrum/pbi/pbi-001/state.json
  [ "$output" = "false" ]
}

@test "mark-ready-to-merge: kind=docs DELETING a .md file -> success (boundary allows .md deletions)" {
  # Positive control: the deletion check must reject only non-.md deletions.
  # Deleting a .md file is within the docs contract and must still succeed.
  _docs_pbi_with_deletion old.md
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "in_progress_merge" ]
  # paths_touched stays AMR-only (the added .md), not the deleted .md.
  run jq -r '.paths_touched | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.paths_touched[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = "notes.md" ]
}
