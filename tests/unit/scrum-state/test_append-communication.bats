#!/usr/bin/env bats
# tests/unit/scrum-state/test_append-communication.bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/append-comm.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/append-comm.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/communications.schema.json" docs/contracts/scrum-state/
  printf '{"max_messages":200,"messages":[]}\n' > .scrum/communications.json
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "append-communication: appends one message with required fields only" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
    --from scrum-master --kind info --content "hello"
  [ "$status" -eq 0 ]
  run jq -r '.messages | length' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "1" ]
  run jq -r '.messages[0].sender_id' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "scrum-master" ]
  run jq -r '.messages[0].recipient_id' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "null" ]
}

@test "append-communication: with all optional fields" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
    --from dev-001-s1 --to scrum-master --role developer \
    --kind report --content "PBI-001 ready" --pbi pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.messages[0].pbi_id' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "pbi-001" ]
  run jq -r '.messages[0].sender_role' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "developer" ]
}

@test "append-communication: 20 concurrent appends — no lost writes" {
  for i in $(seq 1 20); do
    env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
      --from "agent-$i" --kind info --content "m$i" &
  done
  wait
  run jq -r '.messages | length' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "20" ]
}

@test "append-communication: escapes special characters in content" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
    --from a --kind info --content 'has "quotes" and \backslash and \n newlines'
  [ "$status" -eq 0 ]
  run jq -r '.messages[0].content' "$TEST_TMP/.scrum/communications.json"
  [[ "$output" == *'"quotes"'* ]]
}

@test "append-communication: rejects missing required field --from" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" --kind info --content "hi"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--from required"* ]]
}

@test "append-communication: rejects bad --kind" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" --from a --kind frobnicate --content "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --kind"* ]]
}

@test "append-communication: rejects bad --role" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" --from a --kind info --content x --role wibble
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --role"* ]]
}

@test "append-communication: rejects bad --pbi format" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" --from a --kind info --content x --pbi WIBBLE
  [ "$status" -eq 64 ]
}

@test "append-communication: rejects unknown flag" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" --bogus xx --from a --kind info --content x
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "append-communication: caps at max_messages (mirrors hook-side trim)" {
  # Seed with max_messages=3 so cap behaviour is observable without writing 200+ messages.
  printf '{"max_messages":3,"messages":[]}\n' > .scrum/communications.json
  for i in 1 2 3 4 5; do
    env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
      --from "agent-$i" --kind info --content "m$i" >/dev/null
  done
  run jq -r '.messages | length' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "3" ]
  # Oldest messages are trimmed; newest 3 remain.
  run jq -r '.messages[0].sender_id' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "agent-3" ]
  run jq -r '.messages[2].sender_id' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "agent-5" ]
}

@test "append-communication: accepts file_changed (post OD-3 unification)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
    --from hook-dashboard-event --kind file_changed --content "Write on src/x.ts"
  [ "$status" -eq 0 ]
  run jq -r '.messages[0].type' "$TEST_TMP/.scrum/communications.json"
  [ "$output" = "file_changed" ]
}

@test "append-communication: rejects legacy file_change (pre-OD-3 spelling)" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/append-communication.sh" \
    --from a --kind file_change --content "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --kind"* ]]
}
