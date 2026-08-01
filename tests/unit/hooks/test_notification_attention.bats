#!/usr/bin/env bats
# tests/unit/hooks/test_notification_attention.bats
#
# Verifies hooks/notification-attention.sh, the writer of the
# .scrum/attention.json contract consumed by the Mac app.
#
# Contract under test:
#   * Notification → attention.json {pending, type, message, agent?, updated_at}
#   * Stop → attention-context.json, which an idle_prompt Notification with the
#     same prompt_id uses to replace the generic banner text
#   * UserPromptSubmit → pending:false, and never any stdout (UserPromptSubmit
#     stdout is injected into the model's context)
#   * every path exits 0, including malformed stdin
#
# Fixture payloads are sanitized copies of real hook payloads (paths replaced).

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  HOOK="$PROJECT_ROOT/hooks/notification-attention.sh"
  FIXTURES="$PROJECT_ROOT/tests/fixtures"
  SCHEMA_DIR="$PROJECT_ROOT/docs/contracts/scrum-state"
  TEST_TMP="$(mktemp -d /tmp/claude/notification-attention.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/notification-attention.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Feed a fixture payload to the hook.
_run_fixture() {
  run bash "$HOOK" < "$FIXTURES/$1"
}

# Feed a literal JSON payload to the hook.
_run_payload() {
  run bash -c "printf '%s' \"\$1\" | bash '$HOOK'" _ "$1"
}

# -----------------------------------------------------------------
# (a) permission_prompt → attention.json per contract.
# -----------------------------------------------------------------

@test "notification-attention: permission_prompt writes the attention contract" {
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ -f .scrum/attention.json ]
  run jq -e '.pending == true' .scrum/attention.json
  [ "$status" -eq 0 ]
  run jq -r '.type' .scrum/attention.json
  [ "$output" = "permission_prompt" ]
  run jq -r '.message' .scrum/attention.json
  [ "$output" = "Claude needs your permission" ]
  # ISO-8601 UTC, matching the repo-wide get_timestamp format.
  run jq -e '.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' .scrum/attention.json
  [ "$status" -eq 0 ]
  # No session-map entry → the optional agent key is omitted entirely.
  run jq -e 'has("agent")' .scrum/attention.json
  [ "$status" -ne 0 ]
}

@test "notification-attention: written attention.json validates against its schema" {
  command -v jsonschema >/dev/null 2>&1 || skip "jsonschema CLI not installed"
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  run jsonschema --instance .scrum/attention.json "$SCHEMA_DIR/attention.schema.json"
  [ "$status" -eq 0 ]

  _run_fixture hook-stop-turn-end.json
  run jsonschema --instance .scrum/attention-context.json "$SCHEMA_DIR/attention-context.schema.json"
  [ "$status" -eq 0 ]

  # The cleared shape must satisfy the schema too (type/message drop out of
  # `required` only while pending is false).
  _run_fixture hook-user-prompt-submit.json
  run jsonschema --instance .scrum/attention.json "$SCHEMA_DIR/attention.schema.json"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (b) Stop records the recovery context.
# -----------------------------------------------------------------

@test "notification-attention: Stop records prompt_id and last_assistant_message" {
  _run_fixture hook-stop-turn-end.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ -f .scrum/attention-context.json ]
  run jq -r '.prompt_id' .scrum/attention-context.json
  [ "$output" = "4daa18b7-128c-4d44-84ff-c910f21803f8" ]
  run jq -r '.last_assistant_message' .scrum/attention-context.json
  [ "$output" = "What is your favorite color?" ]
  run jq -e '.recorded_at | test("Z$")' .scrum/attention-context.json
  [ "$status" -eq 0 ]

  # Stop must not raise the banner by itself.
  [ ! -f .scrum/attention.json ]
}

# -----------------------------------------------------------------
# (c) Stop → matching idle_prompt inherits the closing message.
# -----------------------------------------------------------------

@test "notification-attention: idle_prompt with matching prompt_id uses the Stop message" {
  _run_fixture hook-stop-turn-end.json
  [ "$status" -eq 0 ]

  _run_fixture hook-notification-idle-prompt.json
  [ "$status" -eq 0 ]

  run jq -r '.type' .scrum/attention.json
  [ "$output" = "idle_prompt" ]
  run jq -r '.message' .scrum/attention.json
  [ "$output" = "What is your favorite color?" ]
}

# -----------------------------------------------------------------
# (d) Non-matching context → generic payload message.
# -----------------------------------------------------------------

@test "notification-attention: idle_prompt with stale context falls back to payload message" {
  # A Stop from some other turn (different prompt_id) — e.g. a teammate
  # session ending between this turn's Stop and its idle Notification.
  jq '.prompt_id = "some-other-turn" | .last_assistant_message = "unrelated"' \
    "$FIXTURES/hook-stop-turn-end.json" > stop-other.json
  run bash "$HOOK" < stop-other.json
  [ "$status" -eq 0 ]

  _run_fixture hook-notification-idle-prompt.json
  [ "$status" -eq 0 ]

  run jq -r '.message' .scrum/attention.json
  [ "$output" = "Claude is waiting for your input" ]
}

@test "notification-attention: idle_prompt with no context file falls back to payload message" {
  _run_fixture hook-notification-idle-prompt.json
  [ "$status" -eq 0 ]
  run jq -r '.message' .scrum/attention.json
  [ "$output" = "Claude is waiting for your input" ]
}

# -----------------------------------------------------------------
# (e) UserPromptSubmit clears — and stays silent on stdout.
# -----------------------------------------------------------------

@test "notification-attention: UserPromptSubmit clears pending with empty stdout" {
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  local before
  before="$(jq -r '.updated_at' .scrum/attention.json)"

  _run_fixture hook-user-prompt-submit.json
  [ "$status" -eq 0 ]
  # UserPromptSubmit stdout is injected into the model's context — it must be
  # empty, or every user prompt would carry hook noise.
  [ -z "$output" ]

  run jq -e '.pending == false' .scrum/attention.json
  [ "$status" -eq 0 ]
  run jq -e --arg before "$before" '.updated_at >= $before' .scrum/attention.json
  [ "$status" -eq 0 ]
}

@test "notification-attention: UserPromptSubmit is a no-op when no attention file exists" {
  _run_fixture hook-user-prompt-submit.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f .scrum/attention.json ]
}

@test "notification-attention: UserPromptSubmit replaces a corrupt attention file" {
  printf 'not json at all' > .scrum/attention.json
  _run_fixture hook-user-prompt-submit.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e '.pending == false' .scrum/attention.json
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (f) Malformed / empty stdin is harmless.
# -----------------------------------------------------------------

@test "notification-attention: broken stdin JSON exits 0 and writes nothing" {
  _run_payload '{"hook_event_name":"Notification", this is not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f .scrum/attention.json ]
  [ ! -f .scrum/attention-context.json ]
}

@test "notification-attention: empty stdin exits 0 and writes nothing" {
  run bash -c ": | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f .scrum/attention.json ]
}

@test "notification-attention: unhandled event names are ignored" {
  _run_payload '{"hook_event_name":"PostToolUse","tool_name":"Write"}'
  [ "$status" -eq 0 ]
  [ ! -f .scrum/attention.json ]
  [ ! -f .scrum/attention-context.json ]
}

# -----------------------------------------------------------------
# (g) agent resolution via session-map.json (written by dashboard-event.sh,
#     which keys the map by the SHORTENED session id).
# -----------------------------------------------------------------

@test "notification-attention: agent is resolved from the shortened session-map key" {
  # dashboard-event.sh stores UUID-style ids as their first segment.
  printf '{"6cc62b08":"dev-001-s1"}\n' > .scrum/session-map.json
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  run jq -r '.agent' .scrum/attention.json
  [ "$output" = "dev-001-s1" ]
}

@test "notification-attention: agent is resolved from a full session-map key" {
  printf '{"6cc62b08-53ff-498c-a915-46405ed2b53f":"scrum-master"}\n' > .scrum/session-map.json
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  run jq -r '.agent' .scrum/attention.json
  [ "$output" = "scrum-master" ]
}

@test "notification-attention: unmapped session omits agent rather than emitting the id" {
  printf '{"deadbeef":"dev-002-s1"}\n' > .scrum/session-map.json
  _run_fixture hook-notification-permission-prompt.json
  [ "$status" -eq 0 ]
  run jq -e 'has("agent")' .scrum/attention.json
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------
# (h) Truncation is codepoint-based, so multi-byte text is never cut
#     mid-character (a byte-based `head -c` would corrupt the JSON).
# -----------------------------------------------------------------

@test "notification-attention: long multibyte Stop message is truncated to 200 codepoints" {
  local long
  long="$(python3 -c 'print("あ" * 300, end="")')"
  jq --arg m "$long" '.last_assistant_message = $m' \
    "$FIXTURES/hook-stop-turn-end.json" > stop-long.json
  run bash "$HOOK" < stop-long.json
  [ "$status" -eq 0 ]

  # Still valid JSON (proves no mid-character cut) and capped at 200 + ellipsis.
  run jq -e '.last_assistant_message | length == 201' .scrum/attention-context.json
  [ "$status" -eq 0 ]
  run jq -e '.last_assistant_message | endswith("…")' .scrum/attention-context.json
  [ "$status" -eq 0 ]

  # The banner inherits the already-truncated text.
  _run_fixture hook-notification-idle-prompt.json
  run jq -e '.message | length == 201' .scrum/attention.json
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# (i) Unknown notification_type degrades to the generic wait, never to a
#     value the consumer cannot branch on.
# -----------------------------------------------------------------

@test "notification-attention: unknown notification_type is normalized to idle_prompt" {
  _run_payload '{"hook_event_name":"Notification","notification_type":"something_new","message":"Heads up","session_id":"s1"}'
  [ "$status" -eq 0 ]
  run jq -r '.type' .scrum/attention.json
  [ "$output" = "idle_prompt" ]
  run jq -r '.message' .scrum/attention.json
  [ "$output" = "Heads up" ]
}

@test "notification-attention: Notification with no message still yields banner text" {
  _run_payload '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s1"}'
  [ "$status" -eq 0 ]
  run jq -r '.message' .scrum/attention.json
  [ "$output" = "Claude is waiting for your input" ]
}
