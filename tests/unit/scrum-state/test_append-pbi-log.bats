#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-pbi-log.bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-pbi-log.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-pbi-log.XXXXXX")"
  cd "$TEST_TMP" || exit 1
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-pbi-log: writes one tab-delimited line" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 design 1 spawn pbi-designer
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.scrum/pbi/pbi-001/pipeline.log" ]
  run wc -l < "$TEST_TMP/.scrum/pbi/pbi-001/pipeline.log"
  [ "${output// /}" = "1" ]
}

@test "append-pbi-log: line has 5 tab-separated fields with timestamp first" {
  "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init 0 created "boot"
  run cat "$TEST_TMP/.scrum/pbi/pbi-001/pipeline.log"
  # Field count: 5 fields → 4 tabs → awk -F"\t" '{print NF}' = 5
  field_count="$(awk -F"\t" '{print NF}' "$TEST_TMP/.scrum/pbi/pbi-001/pipeline.log")"
  [ "$field_count" = "5" ]
  # First field looks like ISO8601 UTC
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "append-pbi-log: appends — preserves prior lines" {
  "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init 0 a "x"
  "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init 0 b "y"
  "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init 0 c "z"
  run wc -l < "$TEST_TMP/.scrum/pbi/pbi-001/pipeline.log"
  [ "${output// /}" = "3" ]
}

@test "append-pbi-log: rejects unknown stage" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 wibble 1 spawn x
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad stage"* ]]
}

@test "append-pbi-log: rejects legacy impl_ut stage (renamed in v2)" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 impl_ut 1 spawn x
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad stage"* ]]
}

@test "append-pbi-log: accepts pbi_review and ut_run stages" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 pbi_review 1 start ok
  [ "$status" -eq 0 ]
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 ut_run 1 start ok
  [ "$status" -eq 0 ]
}

@test "append-pbi-log: rejects bad pbi-id format" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" "BAD ID" init 0 a x
  [ "$status" -eq 64 ]
}

@test "append-pbi-log: rejects non-integer round" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init abc spawn x
  [ "$status" -eq 64 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "append-pbi-log: requires exactly 5 args" {
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-001 init 0 spawn
  [ "$status" -eq 64 ]
}

@test "append-pbi-log: creates pbi directory if missing" {
  [ ! -d "$TEST_TMP/.scrum/pbi/pbi-042" ]
  run "$PROJECT_ROOT/scripts/scrum/append-pbi-log.sh" pbi-042 init 0 created "auto-mkdir"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.scrum/pbi/pbi-042/pipeline.log" ]
}
