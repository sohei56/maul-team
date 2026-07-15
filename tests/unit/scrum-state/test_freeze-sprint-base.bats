#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/freeze-sprint-base.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/freeze-sprint-base.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cat > .scrum/sprint.json <<'EOF'
{"id": "sprint-001", "status": "planning", "started_at": "2026-05-04T10:00:00Z"}
EOF
  git init -q
  git config user.email t@t
  git config user.name t
  git commit -q --allow-empty -m "init"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then rm -rf "$TEST_TMP"; fi
}

@test "freeze-sprint-base: writes base_sha and base_sha_captured_at" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  [ "$status" -eq 0 ]
  run jq -r '.base_sha' .scrum/sprint.json
  [ "${#output}" -ge 7 ]
  run jq -r '.base_sha_captured_at' .scrum/sprint.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "freeze-sprint-base: refuses to overwrite already-frozen base" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  [ "$status" -ne 0 ]
}

@test "freeze-sprint-base: fails when no git repo" {
  rm -rf .git
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  [ "$status" -ne 0 ]
}

@test "freeze-sprint-base: refuses while docs/design/ has uncommitted changes" {
  mkdir -p docs/design/specs
  echo "stub" > docs/design/specs/S-001-example.md
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted docs/design/"* ]]
  [[ "$output" == *"S-001-example.md"* ]]
  run jq -e 'has("base_sha") | not' .scrum/sprint.json
  [ "$status" -eq 0 ]
}

@test "freeze-sprint-base: proceeds once docs/design/ scaffold is committed" {
  mkdir -p docs/design/specs
  echo "stub" > docs/design/specs/S-001-example.md
  git add docs/design/
  git commit -q -m "scaffold"
  # Dirt outside docs/design/ must not block the freeze.
  echo "unrelated" > note.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/freeze-sprint-base.sh"
  [ "$status" -eq 0 ]
  run jq -r '.base_sha' .scrum/sprint.json
  [ "${#output}" -ge 7 ]
}
