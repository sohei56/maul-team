#!/usr/bin/env bats
# tests/unit/hooks/test_stop_gate_state.bats
#
# Verifies the Stop-hook dedup ledger at hooks/lib/stop-gate-state.sh.
# Each test materialises a fresh .scrum/ directory in a tmp cwd, sources
# the lib, and exercises stop_gate_check_and_bump.
#
# Contract under test:
#   * Missing file → FIRST + file created with block_count=1
#   * Corrupted JSON → FIRST (fail-open toward block) + file rewritten
#   * Same <phase, fingerprint> → REPEAT:<N> with N=prev+1
#   * Different phase → FIRST (reset)
#   * Different fingerprint → FIRST (reset)
#   * Atomic write: a partial tmp file must not remain after a successful call

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  LIB="$PROJECT_ROOT/hooks/lib/stop-gate-state.sh"
  TEST_TMP="$(mktemp -d /tmp/claude/stop-gate-state.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/stop-gate-state.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Helper that sources the lib in a subshell and runs the function. Using a
# subshell keeps the parent bats process unaffected by any `set` flags the
# lib might enable, and matches the call pattern in completion-gate.sh.
run_check() {
  local fp="$1"
  local phase="$2"
  bash -c ". '$LIB' && stop_gate_check_and_bump '$fp' '$phase'"
}

# ---------------------------------------------------------------------------
# Missing file path
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: missing file → FIRST + file created" {
  [ ! -f .scrum/stop-gate.json ]
  run run_check "review_incomplete|pbi-001" "review"
  [ "$status" -eq 0 ]
  [ "$output" = "FIRST" ]
  [ -f .scrum/stop-gate.json ]
  run jq -r '.phase' .scrum/stop-gate.json
  [ "$output" = "review" ]
  run jq -r '.fingerprint' .scrum/stop-gate.json
  [ "$output" = "review_incomplete|pbi-001" ]
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "1" ]
  run jq -r '.first_block_at' .scrum/stop-gate.json
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  run jq -r '.last_block_at' .scrum/stop-gate.json
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# Same situation → REPEAT counter
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: same <phase, fingerprint> bumps counter" {
  run run_check "x|y" "review"
  [ "$output" = "FIRST" ]
  run run_check "x|y" "review"
  [ "$output" = "REPEAT:2" ]
  run run_check "x|y" "review"
  [ "$output" = "REPEAT:3" ]
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "3" ]
}

# ---------------------------------------------------------------------------
# Phase change resets
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: phase change resets to FIRST" {
  run run_check "sig" "review"
  [ "$output" = "FIRST" ]
  run run_check "sig" "review"
  [ "$output" = "REPEAT:2" ]
  run run_check "sig" "sprint_review"
  [ "$output" = "FIRST" ]
  run jq -r '.phase' .scrum/stop-gate.json
  [ "$output" = "sprint_review" ]
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Fingerprint change resets even when phase stays
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: fingerprint change resets to FIRST" {
  run run_check "sigA" "review"
  [ "$output" = "FIRST" ]
  run run_check "sigA" "review"
  [ "$output" = "REPEAT:2" ]
  run run_check "sigB" "review"
  [ "$output" = "FIRST" ]
  run jq -r '.fingerprint' .scrum/stop-gate.json
  [ "$output" = "sigB" ]
  run jq -r '.block_count' .scrum/stop-gate.json
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Corrupted JSON → fail-open to FIRST (block side) + rewrite
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: corrupted JSON falls open to FIRST" {
  printf 'not json {{{' > .scrum/stop-gate.json
  run run_check "sig" "review"
  [ "$status" -eq 0 ]
  [ "$output" = "FIRST" ]
  # The lib should have rewritten the file with a valid record.
  run jq -e '.block_count == 1' .scrum/stop-gate.json
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Empty arg → FIRST, file NOT touched (caller bug guard)
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: empty fingerprint returns FIRST and does not write" {
  [ ! -f .scrum/stop-gate.json ]
  run run_check "" "review"
  [ "$status" -eq 0 ]
  [ "$output" = "FIRST" ]
  [ ! -f .scrum/stop-gate.json ]
}

@test "stop_gate_check_and_bump: empty phase returns FIRST and does not write" {
  [ ! -f .scrum/stop-gate.json ]
  run run_check "sig" ""
  [ "$status" -eq 0 ]
  [ "$output" = "FIRST" ]
  [ ! -f .scrum/stop-gate.json ]
}

# ---------------------------------------------------------------------------
# Atomic write: no leftover tmp files after a successful sequence.
# ---------------------------------------------------------------------------

@test "stop_gate_check_and_bump: no tmp files left behind" {
  run run_check "sig" "review"
  run run_check "sig" "review"
  run run_check "other" "review"
  shopt -s nullglob
  set -- .scrum/stop-gate.json.tmp.*
  [ "$#" -eq 0 ]
}
