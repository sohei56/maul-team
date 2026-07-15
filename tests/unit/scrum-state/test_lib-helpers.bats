#!/usr/bin/env bats
# tests/unit/scrum-state/test_lib-helpers.bats — edge cases for the shared
# lib helpers introduced by the RC#6/#7 dedup pass: assert_sprint_id
# (lib/errors.sh) and alloc_next_id (lib/queries.sh).

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/lib-helpers-test.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/lib-helpers-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "assert_sprint_id: rejects bad id with default label and exit 64" {
  run bash -c "source '$PROJECT_ROOT/scripts/scrum/lib/errors.sh' && assert_sprint_id 'nope-1'"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad sprint-id: nope-1"* ]]
}

@test "assert_sprint_id: custom label surfaces in the error message" {
  run bash -c "source '$PROJECT_ROOT/scripts/scrum/lib/errors.sh' && assert_sprint_id '1' --sprint"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --sprint: 1"* ]]
}

@test "assert_sprint_id: accepts a well-formed sprint id" {
  run bash -c "source '$PROJECT_ROOT/scripts/scrum/lib/errors.sh' && assert_sprint_id 'sprint-003'"
  [ "$status" -eq 0 ]
}

@test "alloc_next_id: empty array yields the first padded id" {
  printf '{"entries":[]}\n' > store.json
  run bash -c "source '$PROJECT_ROOT/scripts/scrum/lib/errors.sh' && source '$PROJECT_ROOT/scripts/scrum/lib/queries.sh' && alloc_next_id store.json '.entries' 'imp-' 4"
  [ "$status" -eq 0 ]
  [ "$output" = "imp-0001" ]
}

@test "alloc_next_id: returns max(existing)+1 with the requested prefix and width" {
  printf '{"decisions":[{"id":"dec-0003"},{"id":"dec-0001"}]}\n' > store.json
  run bash -c "source '$PROJECT_ROOT/scripts/scrum/lib/errors.sh' && source '$PROJECT_ROOT/scripts/scrum/lib/queries.sh' && alloc_next_id store.json '.decisions' 'dec-' 4"
  [ "$status" -eq 0 ]
  [ "$output" = "dec-0004" ]
}
