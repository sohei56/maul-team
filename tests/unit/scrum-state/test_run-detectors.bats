#!/usr/bin/env bats
# test_run-detectors.bats — the guard-first detector runner's exit contract.
#
# The runner is the only thing standing between "the ledger says guarded" and
# "a ratchet actually runs", so every arm of its 0/1/2/64 space is pinned here.
# Ledger fixtures are written directly (a test is not an agent tool call, so
# the scrum-state guard does not apply); the wrapper that normally writes them
# is scripts/scrum/update-audit-ledger.sh.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  RUNNER="$PROJECT_ROOT/scripts/scrum/run-detectors.sh"
  TEST_TMP="$(mktemp -d /tmp/claude/run-detectors.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/run-detectors.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  LEDGER=".scrum/audit-ledger.json"
  IDENTITY="notify-order::send-before-write"
}

teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

# ledger_with <status> <detector-json>
# Write a one-class ledger. <detector-json> is a JSON value ("null" or an
# object) for classes[0].detector.
ledger_with() {
  local status="$1" detector="$2"
  jq -n --arg k "$IDENTITY" --arg s "$status" --argjson d "$detector" \
    '{updated_at: "2026-05-04T10:00:00Z",
      classes: [{identity: $k, axis: ["logic-defect"], severity: "high",
                 status: $s, occurrences: [], detector: $d,
                 pbi_ids: [], first_seen_sprint: "sprint-001"}]}' > "$LEDGER"
}

# detector_obj <command>
detector_obj() {
  jq -n --arg c "$1" \
    '{command: $c, registered_sprint: "sprint-001",
      verified_at: "2026-05-04T10:00:00Z", verified_exit: 0}'
}

@test "run-detectors: no ledger → silent exit 0" {
  run "$RUNNER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run-detectors: ledger with no guarded class → silent exit 0" {
  ledger_with open "$(detector_obj 'exit 1')"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run-detectors: guarded + clean detector → exit 0, no output" {
  ledger_with guarded "$(detector_obj 'true')"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run-detectors: violations → exit 1 with the offending lines, identity-prefixed" {
  ledger_with guarded "$(detector_obj "printf 'src/a.py:12: bad\\nsrc/b.py:3: bad\\n'; exit 1")"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "\[$IDENTITY\] src/a.py:12: bad"
  echo "$output" | grep -q "\[$IDENTITY\] src/b.py:3: bad"
}

@test "run-detectors: stderr from a detector is captured too" {
  ledger_with guarded "$(detector_obj 'echo "on stderr" >&2; exit 1')"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "on stderr"
}

@test "run-detectors: a violating detector with no output still names the class" {
  ledger_with guarded "$(detector_obj 'exit 1')"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "\[$IDENTITY\] detector reported violations (exit 1)"
}

@test "run-detectors: missing command (exit 127) → exit 2, never clean" {
  ledger_with guarded "$(detector_obj 'definitely-not-a-real-command-xyz')"
  run "$RUNNER"
  # Fail-closed: an unrunnable ratchet is an error, not a pass.
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "DETECTOR COULD NOT EXECUTE"
  echo "$output" | grep -q "exit 127"
}

@test "run-detectors: guarded class with detector:null → exit 2" {
  # Schema-valid by design (the invariant lives in update-audit-ledger.sh),
  # so the runner must refuse to call it clean.
  ledger_with guarded null
  run "$RUNNER"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "no detector.command registered"
}

@test "run-detectors: a hanging detector is killed at the configured timeout → exit 2" {
  printf '%s\n' '{"detectors":{"timeout_seconds":1}}' > .scrum/config.json
  ledger_with guarded "$(detector_obj 'sleep 999')"
  START="$(date +%s)"
  run "$RUNNER"
  END="$(date +%s)"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "timed out after 1s"
  # The bound is real, not advisory: well under the 120 s default.
  [ "$((END - START))" -lt 20 ]
}

@test "run-detectors: an unparsable timeout_seconds falls back to the default" {
  printf '%s\n' '{"detectors":{"timeout_seconds":"soon"}}' > .scrum/config.json
  ledger_with guarded "$(detector_obj 'true')"
  run "$RUNNER" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.timeout_seconds')" = "120" ]
}

@test "run-detectors: the worst outcome wins (violations + unexecutable → 2)" {
  jq -n --argjson a "$(detector_obj 'echo hit; exit 1')" \
        --argjson b "$(detector_obj 'definitely-not-a-real-command-xyz')" \
    '{classes: [
        {identity: "aaa-class::aaa-pattern", status: "guarded", detector: $a,
         first_seen_sprint: "sprint-001"},
        {identity: "zzz-class::zzz-pattern", status: "guarded", detector: $b,
         first_seen_sprint: "sprint-001"}]}' > "$LEDGER"
  run "$RUNNER"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "\[aaa-class::aaa-pattern\] hit"
  echo "$output" | grep -q "\[zzz-class::zzz-pattern\] DETECTOR COULD NOT EXECUTE"
}

@test "run-detectors: a non-guarded class is not run" {
  jq -n --argjson a "$(detector_obj 'echo SHOULD-NOT-RUN; exit 1')" \
        --argjson b "$(detector_obj 'true')" \
    '{classes: [
        {identity: "aaa-class::aaa-pattern", status: "open", detector: $a,
         first_seen_sprint: "sprint-001"},
        {identity: "zzz-class::zzz-pattern", status: "guarded", detector: $b,
         first_seen_sprint: "sprint-001"}]}' > "$LEDGER"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "SHOULD-NOT-RUN"
}

@test "run-detectors: --check runs a non-guarded class's detector" {
  # This is the probe update-audit-ledger.sh uses BEFORE a class is guarded,
  # so it must ignore status entirely.
  ledger_with open "$(detector_obj 'echo still-ran; exit 1')"
  run "$RUNNER" --check "$IDENTITY"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "still-ran"
}

@test "run-detectors: --check on a clean detector exits 0" {
  ledger_with sweeping "$(detector_obj 'true')"
  run "$RUNNER" --check "$IDENTITY"
  [ "$status" -eq 0 ]
}

@test "run-detectors: --check on an identity absent from the ledger → 64" {
  ledger_with guarded "$(detector_obj 'true')"
  run "$RUNNER" --check "other-class::other-pattern"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "is not a class in"
}

@test "run-detectors: --check with no ledger at all → 64" {
  run "$RUNNER" --check "$IDENTITY"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "no ledger"
}

@test "run-detectors: --check rejects a malformed identity without touching the ledger" {
  ledger_with guarded "$(detector_obj 'true')"
  for bad in "Foo::bar" "a::b::c" "path/to/x.py::sym" "nocolons"; do
    run "$RUNNER" --check "$bad"
    [ "$status" -eq 64 ]
  done
}

@test "run-detectors: --check without an argument → 64" {
  run "$RUNNER" --check
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "requires an <identity>"
}

@test "run-detectors: unknown flag → 64 with the usage line" {
  run "$RUNNER" --bogus
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "unknown flag: --bogus"
  echo "$output" | grep -q "usage: run-detectors.sh"
}

@test "run-detectors: --json emits a valid document even with nothing to run" {
  # The smoke-test skill distinguishes 'no guarded classes' from 'all clean'
  # by .detectors|length, so the empty case must still be JSON.
  run "$RUNNER" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.exit')" = "0" ]
  [ "$(echo "$output" | jq -r '.detectors | length')" = "0" ]
}

@test "run-detectors: --json reports identity, exit, outcome and output lines" {
  ledger_with guarded "$(detector_obj "printf 'src/a.py:12: bad\\n'; exit 3")"
  run "$RUNNER" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.exit')" = "1" ]
  [ "$(echo "$output" | jq -r '.detectors[0].identity')" = "$IDENTITY" ]
  [ "$(echo "$output" | jq -r '.detectors[0].exit')" = "3" ]
  [ "$(echo "$output" | jq -r '.detectors[0].outcome')" = "violations" ]
  [ "$(echo "$output" | jq -r '.detectors[0].output[0]')" = "src/a.py:12: bad" ]
}

@test "run-detectors: --json names why an unexecutable detector failed" {
  ledger_with guarded null
  run "$RUNNER" --json
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | jq -r '.detectors[0].outcome')" = "unexecutable" ]
  echo "$output" | jq -r '.detectors[0].reason' | grep -q "no detector.command"
}

@test "run-detectors: output is capped at 50 lines per detector" {
  ledger_with guarded "$(detector_obj 'seq 1 500; exit 1')"
  run "$RUNNER" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.detectors[0].output | length')" = "50" ]
}

@test "run-detectors: the detector runs from the repo root with stdin closed" {
  ledger_with guarded "$(detector_obj 'pwd; head -c 1 || true; exit 1')"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  # The detector inherits the runner's cwd. /tmp may itself be a symlink
  # (macOS), so accept either the logical or the resolved form.
  echo "$output" | grep -qF "$TEST_TMP" \
    || echo "$output" | grep -qF "$(cd "$TEST_TMP" && pwd -P)"
}

@test "run-detectors: never writes to the ledger" {
  ledger_with guarded "$(detector_obj 'echo x; exit 1')"
  BEFORE="$(cat "$LEDGER")"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  [ "$(cat "$LEDGER")" = "$BEFORE" ]
}
