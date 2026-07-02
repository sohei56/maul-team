#!/usr/bin/env bats
# tests/unit/scrum-state/test_state-guard-hook.bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  HOOK="$PROJECT_ROOT/hooks/pre-tool-use-scrum-state-guard.sh"
  TEST_TMP="$(mktemp -d /tmp/claude/state-guard.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/state-guard.XXXXXX")"
  cd "$TEST_TMP" || exit 1
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# --- Block cases ---

@test "guard: blocks Edit on .scrum/backlog.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\".scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard: blocks Write on .scrum/state.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks MultiEdit on .scrum/sprint.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\".scrum/sprint.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Edit on .scrum/pbi/pbi-001/state.json (nested)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\".scrum/pbi/pbi-001/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with jq redirect into .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . .scrum/backlog.json > .scrum/backlog.json.tmp && mv .scrum/backlog.json.tmp .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with tee into .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo {} | tee .scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with jq -i" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq -i .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with sed -i on .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/foo/bar/ .scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with mv into .scrum/foo.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv /tmp/x.json .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

# --- v2: tightened path normalization ---

@test "guard: blocks Edit on ./.scrum/backlog.json (./prefix bypass)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"./.scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Write on absolute path under \$PWD/.scrum/" {
  run bash -c "$HOOK <<< \"{\\\"tool_name\\\":\\\"Write\\\",\\\"tool_input\\\":{\\\"file_path\\\":\\\"$PWD/.scrum/state.json\\\"}}\""
  [ "$status" -eq 2 ]
}

@test "guard: blocks Edit on .scrum/./pbi/.//x.json (collapsed ./ segments)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\".scrum/./pbi/./pbi-001/state.json\"}}'"
  [ "$status" -eq 2 ]
}

# --- v2: bypass-via-substring is now blocked ---

@test "guard: blocks Bash with wrapper substring + raw mv (substring bypass)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"# scripts/scrum/foo.sh note\\\\nmv /tmp/x.json .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with echo .scrum/scripts/ + raw redirect" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo .scrum/scripts/ > /dev/null; jq . in.json > .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with mv into absolute .scrum/*.json path" {
  run bash -c "$HOOK <<< \"{\\\"tool_name\\\":\\\"Bash\\\",\\\"tool_input\\\":{\\\"command\\\":\\\"mv /tmp/x.json $PWD/.scrum/backlog.json\\\"}}\""
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with cp into .scrum/*.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp /tmp/x.json .scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with awk -i inplace on .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"awk -i inplace 1 .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash with truncate on .scrum/*.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"truncate -s 0 .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

# --- Allow cases ---

@test "guard: allows Bash that calls scripts/scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"scripts/scrum/update-backlog-status.sh pbi-001 review\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash with full env prefix calling scripts/scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli scripts/scrum/append-communication.sh --from a --kind info --content x\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash that calls .scrum/scripts/ (deployed layout)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\".scrum/scripts/update-backlog-status.sh pbi-001 review\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash with env prefix calling .scrum/scripts/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli .scrum/scripts/append-communication.sh --from a --kind info --content x\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash that only reads .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat .scrum/backlog.json | jq .items\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash that greps .scrum/" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep pbi-001 .scrum/backlog.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Edit on non-.scrum file" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"src/foo.py\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Write to .scrum/foo.txt (only .json files are guarded)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/notes.txt\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Read on .scrum/state.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\".scrum/state.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Glob, Grep, etc." {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Glob\",\"tool_input\":{\"pattern\":\".scrum/*.json\"}}'"
  [ "$status" -eq 0 ]
}

# --- Artifact carve-out: agent-authored review/metric JSON is writable ---
# These dirs have NO .scrum/scripts/* wrapper and are written directly by
# design (cross-review SM outputs, PBI pipeline coverage/AC maps).

@test "guard: allows Write to .scrum/reviews/static-analysis-r1.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/reviews/static-analysis-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash redirect into .scrum/reviews/static-analysis-r1.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq -s . parts/*.json > .scrum/reviews/static-analysis-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Write to .scrum/pbi/pbi-001/metrics/coverage-r2.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/pbi/pbi-001/metrics/coverage-r2.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Write to .scrum/pbi/pbi-001/ut/ac-coverage-r1.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/pbi/pbi-001/ut/ac-coverage-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows tee into .scrum/pbi/pbi-001/metrics/test-results-r1.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat raw.json | tee .scrum/pbi/pbi-001/metrics/test-results-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows mv into .scrum/reviews/ artifact json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv /tmp/sa.json .scrum/reviews/static-analysis-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: still blocks Write to .scrum/pbi/pbi-001/state.json (state under pbi/, NOT carved out)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/pbi/pbi-001/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: still blocks redirect to .scrum/backlog.json (carve-out is dir-scoped)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . in.json > .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

# --- Carve-out must not enable a multi-destination bypass ---
# A compound command where an exempt artifact write precedes an SSOT write
# must still block (the exempt path must not mask the SSOT sibling).

@test "guard: blocks compound redirect when SSOT write follows an exempt artifact write" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . a > .scrum/reviews/ok.json; jq . b > .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks compound redirect when SSOT write precedes an exempt artifact write" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . a > .scrum/backlog.json; jq . b > .scrum/reviews/ok.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks compound mv when exempt artifact mv masks an SSOT mv" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv /tmp/a.json .scrum/reviews/ok.json && mv /tmp/b.json .scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: allows compound redirect when ALL destinations are exempt artifacts" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . a > .scrum/reviews/r1.json; jq . b > .scrum/pbi/pbi-001/metrics/coverage-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows reading an SSOT json while writing an exempt artifact json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq .items .scrum/backlog.json > .scrum/reviews/summary.json\"}}'"
  [ "$status" -eq 0 ]
}

# --- Worktree symlink normalization (RC#12 / T1-9) ---
# Each worktree has a .scrum -> ../../../.scrum symlink, so a write to
# .scrum/worktrees/<pbi>/.scrum/<x> targets the real shared SSOT and must be
# guarded identically to the main-repo form. Stripping the worktree prefix
# both keeps SSOT json blocked AND lets exempt-artifact writes through.

@test "guard: blocks Write to worktree-symlinked .scrum/backlog.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/worktrees/pbi-001/.scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard: blocks Edit to worktree-symlinked .scrum/pbi/pbi-001/state.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\".scrum/worktrees/pbi-001/.scrum/pbi/pbi-001/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash redirect to worktree-symlinked .scrum/backlog.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . in.json > .scrum/worktrees/pbi-001/.scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: allows Write to worktree-symlinked exempt artifact (reviews)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/worktrees/pbi-001/.scrum/reviews/static-analysis-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Write to worktree-symlinked exempt artifact (metrics)" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".scrum/worktrees/pbi-001/.scrum/pbi/pbi-001/metrics/coverage-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

# --- rm / unlink of SSOT json (OD-4) ---

@test "guard: blocks Bash rm of .scrum/sprint.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm .scrum/sprint.json\"}}'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard: blocks Bash rm -f of .scrum/backlog.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -f .scrum/backlog.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash rm -rf of nested .scrum/pbi/pbi-001/state.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf .scrum/pbi/pbi-001/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: blocks Bash unlink of .scrum/state.json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"unlink .scrum/state.json\"}}'"
  [ "$status" -eq 2 ]
}

@test "guard: does NOT block .scrum/scripts/rollover-sprint.sh invocation" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\".scrum/scripts/rollover-sprint.sh\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash rm of an exempt review artifact json" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm .scrum/reviews/static-analysis-r1.json\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: allows Bash rm of a non-json .scrum file" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm .scrum/notes.txt\"}}'"
  [ "$status" -eq 0 ]
}

@test "guard: does NOT block 'confirm' word colliding with rm" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo confirm .scrum/backlog.json is fine\"}}'"
  [ "$status" -eq 0 ]
}

# --- Fail-open cases (malformed input) ---

@test "guard: empty payload → allow" {
  run bash -c "$HOOK <<< ''"
  [ "$status" -eq 0 ]
}

@test "guard: malformed JSON payload → allow" {
  run bash -c "$HOOK <<< 'not json {{{'"
  [ "$status" -eq 0 ]
}

@test "guard: payload with no tool_name → allow" {
  run bash -c "$HOOK <<< '{\"foo\":\"bar\"}'"
  [ "$status" -eq 0 ]
}

@test "guard: payload with empty tool_input → allow" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Edit\"}'"
  [ "$status" -eq 0 ]
}

@test "guard: comment-only Bash (no actual write) → allow" {
  run bash -c "$HOOK <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"# this comment mentions .scrum/foo.json but does nothing\"}}'"
  [ "$status" -eq 0 ]
}
