#!/usr/bin/env bats
# tests/lint/detector-gate-wiring.bats — a guard-first detector is only worth
# anything if the whole chain holds at once: the merge path calls the runner,
# the state schema admits the failure it records, the SM skill knows what to do
# with it, the Sprint-level net records it, and `guarded` can be reached only
# through the one wrapper that verifies the wiring.
#
# Break any link and the ledger keeps claiming a class is guarded while nothing
# checks it — the exact silent-pass state the fail-closed design exists to
# prevent. Prose and shell both drift silently, so pin them here.
#
# Every matcher is exercised against a negative fixture in this file, so a
# regression that neuters a check fails loudly instead of passing vacuously.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MERGE="$PROJECT_ROOT/scripts/scrum/merge-pbi.sh"
  RUNNER="$PROJECT_ROOT/scripts/scrum/run-detectors.sh"
  MARK="$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh"
  PBI_STATE_SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json"
  CONFIG_SCHEMA="$PROJECT_ROOT/docs/contracts/scrum-state/config.schema.json"
  MERGE_SKILL="$PROJECT_ROOT/skills/pbi-merge/SKILL.md"
  SMOKE_SKILL="$PROJECT_ROOT/skills/smoke-test/SKILL.md"
  DETECTORS_REF="$PROJECT_ROOT/skills/codebase-audit/references/detectors.md"
}

# The one sanctioned writer of classes[].status. Kept as a variable so the
# assertion below reads as policy, not as a grep incantation.
LEDGER_WRAPPER="scripts/scrum/update-audit-ledger.sh"

# ---------------------------------------------------------------------------
# The merge path
# ---------------------------------------------------------------------------

@test "merge-pbi.sh invokes run-detectors.sh" {
  # update-audit-ledger.sh `set-status guarded` greps the DEPLOYED merge-pbi.sh
  # for exactly this token to prove the target is wired; losing it silently
  # un-gates every guarded class.
  grep -q 'run-detectors.sh' "$MERGE"
}

@test "the runner exists and is executable" {
  # setup-user.sh chmod +x's what it copies, but a source file committed
  # non-executable makes merge-pbi.sh's `[ -x ]` guard skip the gate here.
  [ -x "$RUNNER" ]
}

@test "the detector gate runs before the regression gate" {
  local det reg
  det="$(grep -n 'Detector gate:' "$MERGE" | head -1 | cut -d: -f1)"
  reg="$(grep -n 'Regression gate:' "$MERGE" | head -1 | cut -d: -f1)"
  [ -n "$det" ] && [ -n "$reg" ]
  # Cheap + deterministic + class-specific first; a slow suite must not mask it.
  [ "$det" -lt "$reg" ]
}

@test "the detector gate is fail-closed: any non-zero runner exit records a failure" {
  # `-ne 0` (not `-eq 1`) is what makes a broken detector fail the merge.
  grep -q 'DET_RC" -eq 0' "$MERGE"
  grep -q 'detector_regression' "$MERGE"
  # No arm may downgrade rc=2 to a pass.
  ! grep -qE 'DET_RC["'"'"']? *(-eq|==) *1' "$MERGE"
}

@test "the merge failure message names the ledger escape hatch" {
  grep -q 'update-audit-ledger.sh set-status' "$MERGE"
  grep -q -- '--status open' "$MERGE"
}

@test "the gate records then rolls back, like every other post-merge arm" {
  # Recording BEFORE the reset is what keeps state consistent when the reset
  # itself fails (which is exit 3, never the failure matrix).
  local slice
  slice="$(awk '/# Detector gate:/{f=1} f; /^# Regression gate:/{exit}' "$MERGE")"
  printf '%s' "$slice" | grep -q 'mark-pbi-merge-failure.sh" "$PBI" detector_regression "$PRE_HEAD"'
  printf '%s' "$slice" | grep -q 'die 3 "CRITICAL: detector_regression but failed to record'
  printf '%s' "$slice" | grep -q 'die 2 "detector_regression'
  printf '%s' "$slice" | grep -q 'die 3 "CRITICAL: rollback failed after detector_regression'
}

@test "mark-pbi-merge-failure.sh accepts the kind and maps it to the prefixed reason" {
  grep -q 'conflict|artifact_missing|regression|detector_regression' "$MARK"
  grep -qE 'detector_regression\)[[:space:]]*ESC_REASON="merge_detector_regression"' "$MARK"
}

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

@test "pbi-state.schema.json carries both new enum values" {
  run jq -e '.properties.merge_failure.properties.kind.enum | index("detector_regression")' \
    "$PBI_STATE_SCHEMA"
  [ "$status" -eq 0 ]
  run jq -e '.properties.escalation_reason.enum | index("merge_detector_regression")' \
    "$PBI_STATE_SCHEMA"
  [ "$status" -eq 0 ]
}

@test "the schema's naming-convention description covers the new pair" {
  local desc
  desc="$(jq -r '.description' "$PBI_STATE_SCHEMA")"
  printf '%s' "$desc" | grep -q 'detector_regression'
  printf '%s' "$desc" | grep -q 'merge_detector_regression'
}

@test "config.schema.json documents detectors.timeout_seconds" {
  run jq -e '.properties.detectors.properties.timeout_seconds.type == "integer"' "$CONFIG_SCHEMA"
  [ "$status" -eq 0 ]
  # The default is a behaviour contract shared with the runner, so it must be
  # written down where an operator will look.
  jq -r '.properties.detectors.properties.timeout_seconds.description' "$CONFIG_SCHEMA" \
    | grep -q '120'
  grep -q 'timeout_seconds' "$RUNNER"
}

# ---------------------------------------------------------------------------
# The instruction surface
# ---------------------------------------------------------------------------

@test "pbi-merge/SKILL.md documents detector_regression in the failure matrix" {
  local matrix
  matrix="$(awk '/- `detector_regression` →/{f=1} f; /^   Note: `merge_failure.kind`/{exit}' "$MERGE_SKILL")"
  [ -n "$matrix" ]
  printf '%s' "$matrix" | grep -q 'DETECTOR_REGRESSION log=.scrum/pbi/<pbi-id>/detector-regression.log'
  printf '%s' "$matrix" | grep -q 'update-audit-ledger.sh set-status'
  # Both failing modes must be named, or an SM reads a broken ratchet as a
  # code defect and sends the Developer chasing nothing.
  printf '%s' "$matrix" | grep -q 'DETECTOR COULD NOT EXECUTE'
  grep -q 'merge_detector_regression' "$MERGE_SKILL"
}

@test "pbi-merge/SKILL.md promotes a merged detector PBI through the wrapper, after the merge" {
  grep -q 'update-audit-ledger.sh register-detector' "$MERGE_SKILL"
  grep -q 'update-audit-ledger.sh set-status' "$MERGE_SKILL"
  grep -q -- '--status guarded' "$MERGE_SKILL"
  # The ordering rationale is the whole reason promotion is not the
  # Developer's job; losing it invites moving the call back into the pipeline.
  grep -q 'does not exist on `main`' "$MERGE_SKILL"
  # A promotion failure must never be escalated into a merge failure.
  grep -q 'never fails the merge' "$MERGE_SKILL"
}

@test "smoke-test/SKILL.md records the detectors category" {
  grep -q 'run-detectors.sh' "$SMOKE_SKILL"
  grep -q -- '--name detectors' "$SMOKE_SKILL"
  # rc=2 is `failed`, never `skipped`: a broken ratchet is a failure.
  grep -q 'a broken ratchet is a failure, not an absence' "$SMOKE_SKILL"
  grep -q -- "--status skipped --runner-command 'no guarded classes'" "$SMOKE_SKILL"
}

@test "the detector contract reference exists and states the exit space" {
  [ -f "$DETECTORS_REF" ]
  grep -q 'Exit `0` = clean' "$DETECTORS_REF"
  grep -q '127' "$DETECTORS_REF"
  grep -q 'Not closed by this check' "$DETECTORS_REF"
}

# ---------------------------------------------------------------------------
# The single choke point
# ---------------------------------------------------------------------------

@test "no write path to status=guarded exists outside update-audit-ledger.sh" {
  # `guarded` is only safe as a status because reaching it proves the wiring.
  # A second writer anywhere re-opens the hole.
  local hits
  hits="$(cd "$PROJECT_ROOT" && grep -rlE '\.status[[:space:]]*=[[:space:]]*"guarded"' \
    scripts hooks 2>/dev/null || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$LEDGER_WRAPPER" ] || {
      echo "unexpected writer of status=guarded: $f" >&2
      return 1
    }
  done <<< "$hits"
}

@test "run-detectors.sh only reads the guarded status, never assigns it" {
  grep -q 'select(.status == "guarded")' "$RUNNER"
  ! grep -qE '\.status[[:space:]]*=[[:space:]]*"guarded"' "$RUNNER"
  # Read-only by contract: the runner records results nowhere.
  ! grep -q 'atomic_write' "$RUNNER"
}

# ---------------------------------------------------------------------------
# Negative fixtures — prove the matchers above actually fire.
# ---------------------------------------------------------------------------

@test "negative fixture: an unwired merge path fails the wiring checks" {
  local fixture
  fixture="$BATS_TEST_TMPDIR/unwired-merge.sh"
  cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bash
# Regression gate: run a project-configured command.
if ! bash -c "$REG_CMD" >"$REG_LOG" 2>&1; then
  "$HERE/mark-pbi-merge-failure.sh" "$PBI" regression "$PRE_HEAD" "$REG_LOG"
fi
FIXTURE
  ! grep -q 'run-detectors.sh' "$fixture"
  ! grep -q 'detector_regression' "$fixture"
  ! grep -q 'update-audit-ledger.sh set-status' "$fixture"
}

@test "negative fixture: a fail-OPEN gate is rejected" {
  local fixture
  fixture="$BATS_TEST_TMPDIR/fail-open.sh"
  cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bash
"$HERE/run-detectors.sh" >"$DET_LOG" 2>&1 || DET_RC=$?
# WRONG: only violations fail; a broken detector (rc=2) sails through.
if [ "$DET_RC" -eq 1 ]; then
  die 2 "detector_regression"
fi
FIXTURE
  # The real merge path must not match this shape …
  ! grep -qE 'DET_RC["'"'"']? *(-eq|==) *1' "$MERGE"
  # … while the fixture does, proving the matcher is not vacuous.
  grep -qE 'DET_RC["'"'"']? *(-eq|==) *1' "$fixture"
}

@test "negative fixture: a stray guarded writer is caught" {
  local fixture
  fixture="$BATS_TEST_TMPDIR/stray-writer.sh"
  cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bash
jq '(.classes[] | select(.identity == $k)).status = "guarded"' ledger.json
FIXTURE
  grep -qE '\.status[[:space:]]*=[[:space:]]*"guarded"' "$fixture"
}

@test "negative fixture: a schema without the new enum values fails" {
  local fixture
  fixture="$BATS_TEST_TMPDIR/old-pbi-state.schema.json"
  cat > "$fixture" <<'FIXTURE'
{"properties": {
  "escalation_reason": {"enum": [null, "merge_conflict", "merge_regression"]},
  "merge_failure": {"properties": {"kind": {"enum": ["conflict", "regression"]}}}}}
FIXTURE
  run jq -e '.properties.merge_failure.properties.kind.enum | index("detector_regression")' "$fixture"
  [ "$status" -ne 0 ]
  run jq -e '.properties.escalation_reason.enum | index("merge_detector_regression")' "$fixture"
  [ "$status" -ne 0 ]
}
