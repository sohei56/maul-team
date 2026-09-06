#!/usr/bin/env bats
# tests/unit/scrum-state/test_update-audit-ledger.bats — the sole writer of
# .scrum/audit-ledger.json.
#
# The ledger's whole value is that a status can be TRUSTED without re-reading
# the repo, so nearly every test here is a negative: the wrapper must refuse a
# `guarded` that no gate backs, an `accepted` citing a decision that does not
# exist, and a `closed` with neither a done PBI nor a re-runnable zero-check.
#
# Tests run against a DEPLOYED layout (.scrum/scripts/ + docs/contracts/
# scrum-state/) rather than the source tree, because two of the four `guarded`
# preconditions are statements about the deployment: the sibling merge-pbi.sh
# must grep as invoking run-detectors.sh, and the sibling runner must actually
# execute. Both are stubbed here — merge-pbi.sh as a file next to the wrapper
# copy, the runner through $SCRUM_RUN_DETECTORS.

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/audit-ledger.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/audit-ledger.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/scripts/lib .scrum/po docs/contracts/scrum-state
  cp "$PROJECT_ROOT/scripts/scrum/update-audit-ledger.sh" .scrum/scripts/
  cp "$PROJECT_ROOT/scripts/scrum/lib/"*.sh .scrum/scripts/lib/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/audit-ledger.schema.json" \
     "$PROJECT_ROOT/docs/contracts/scrum-state/backlog.schema.json" \
     docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/tests/fixtures/valid-backlog.json" .scrum/backlog.json
  W="$TEST_TMP/.scrum/scripts/update-audit-ledger.sh"
  LEDGER="$TEST_TMP/.scrum/audit-ledger.json"
  K="notify-order::send-before-write"
  # Default deployment state = today's tree: merge-pbi.sh exists and does NOT
  # call the detector runner, so `guarded` is unreachable unless a test wires it.
  printf '#!/usr/bin/env bash\necho stub-merge\n' > .scrum/scripts/merge-pbi.sh
  chmod +x .scrum/scripts/merge-pbi.sh
  _mk_runner 0 runner0.sh
  _mk_runner 1 runner1.sh
  _mk_runner 2 runner2.sh
  _mk_runner 64 runner64.sh
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# A stub run-detectors.sh with a fixed exit code from the runner's frozen
# space (0 clean / 1 violations / 2 could-not-execute / 64 usage or unknown
# identity), injected through the documented $SCRUM_RUN_DETECTORS override.
_mk_runner() {
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$TEST_TMP/$2"
  chmod +x "$TEST_TMP/$2"
}

# Make the deployed merge path grep as wired (precondition (b) of `guarded`).
_wire_merge() {
  printf '#!/usr/bin/env bash\n"$HERE/run-detectors.sh" >"$LOG" 2>&1\n' \
    > "$TEST_TMP/.scrum/scripts/merge-pbi.sh"
}

_seed_class() {
  "$W" upsert-class --identity "$K" --sprint sprint-001 --axis logic-defect --severity high >/dev/null
}

_seed_decisions() {
  cat > .scrum/po/decisions.json <<'EOF'
{"decisions":[
 {"id":"dec-0001","timestamp":"2026-01-01T00:00:00Z","kind":"defect_triage","decision":"reject","rationale":"accepted risk","assumption":false},
 {"id":"dec-0002","timestamp":"2026-01-01T00:00:00Z","kind":"sprint_goal_approval","decision":"approve","rationale":"x","assumption":false},
 {"id":"dec-0003","timestamp":"2026-01-01T00:00:00Z","kind":"spec_clarification","decision":"use option B","rationale":"x","assumption":false}
]}
EOF
}

# Link pbi-001 and set its backlog status.
_link_pbi_with_status() {
  "$W" link-pbi --identity "$K" --pbi pbi-001 --role "${2:-sweep}" >/dev/null
  jq --arg s "$1" '.items[0].status = $s' .scrum/backlog.json > b.tmp
  mv b.tmp .scrum/backlog.json
}

# --- upsert-class -----------------------------------------------------------

@test "upsert-class: creates the class open, seeds the file, and stamps both sprints" {
  run "$W" upsert-class --identity "$K" --sprint sprint-001 --axis logic-defect --severity high
  [ "$status" -eq 0 ]
  [ "$output" = "$K" ]
  run jq -r '.classes[0] | "\(.status)|\(.first_seen_sprint)|\(.last_confirmed_sprint)|\(.severity)|\(.occurrences|length)|\(.detector)"' "$LEDGER"
  [ "$output" = "open|sprint-001|sprint-001|high|0|null" ]
  # The seed carries updated_at so atomic_write keeps it fresh from then on.
  run jq -e 'has("updated_at")' "$LEDGER"
  [ "$status" -eq 0 ]
}

@test "upsert-class: unions axis, raises severity monotonically, never lowers, never touches status" {
  _seed_class
  "$W" set-status --identity "$K" --status accepted --dec-id dec-0001 >/dev/null 2>&1 || true
  run "$W" upsert-class --identity "$K" --sprint sprint-002 --axis redundancy,logic-defect --severity critical
  [ "$status" -eq 0 ]
  run jq -c '.classes[0].axis' "$LEDGER"
  [ "$output" = '["logic-defect","redundancy"]' ]
  run jq -r '.classes[0].severity' "$LEDGER"
  [ "$output" = "critical" ]
  # A later, lower rating must not erase the worst sighting.
  run "$W" upsert-class --identity "$K" --sprint sprint-003 --severity low
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].severity' "$LEDGER"
  [ "$output" = "critical" ]
  run jq -r '.classes[0].last_confirmed_sprint' "$LEDGER"
  [ "$output" = "sprint-003" ]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "upsert-class: rejects an axis outside the schema enum" {
  run "$W" upsert-class --identity "$K" --sprint sprint-001 --axis not-an-axis
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --axis value"* ]]
}

@test "upsert-class: rejects a severity outside the schema enum" {
  run "$W" upsert-class --identity "$K" --sprint sprint-001 --severity medium
  [ "$status" -eq 64 ]
}

@test "upsert-class: rejects a bad --sprint" {
  run "$W" upsert-class --identity "$K" --sprint 001
  [ "$status" -eq 64 ]
}

# --- identity (invariant 1: reject, never repair) ---------------------------

@test "identity: an upper-case, three-part, or path-shaped key is refused, not normalized" {
  local bad
  for bad in 'Foo::bar' 'a::b::c' 'path/to/x.py::sym' 'trailing-::x' 'no-separator'; do
    run "$W" upsert-class --identity "$bad" --sprint sprint-001
    [ "$status" -eq 64 ]
    [[ "$output" == *"bad --identity"* ]]
  done
  [ ! -f "$LEDGER" ]
}

@test "identity: an unknown class is refused with the upsert-class hint" {
  _seed_class
  run "$W" confirm-seen --identity other-class::other-pattern --sprint sprint-002
  [ "$status" -eq 64 ]
  [[ "$output" == *"upsert-class"* ]]
}

# --- add-occurrences --------------------------------------------------------

@test "add-occurrences: union keeps an unseen entry and bumps last_seen_sprint on a re-seen one" {
  _seed_class
  cat > occ1.json <<'EOF'
[{"path":"a.py","symbol":"f","note":"n1"},{"path":"b.py"}]
EOF
  run "$W" add-occurrences --identity "$K" --sprint sprint-001 --from occ1.json
  [ "$status" -eq 0 ]
  cat > occ2.json <<'EOF'
[{"path":"a.py","symbol":"f"},{"path":"c.py"}]
EOF
  run "$W" add-occurrences --identity "$K" --sprint sprint-003 --from occ2.json
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].occurrences | length' "$LEDGER"
  [ "$output" = "3" ]
  # re-seen: last_seen bumped, first_seen and note preserved
  run jq -r '.classes[0].occurrences[] | select(.path=="a.py") | "\(.first_seen_sprint)|\(.last_seen_sprint)|\(.note)"' "$LEDGER"
  [ "$output" = "sprint-001|sprint-003|n1" ]
  # unseen this round: kept with its OLD last_seen_sprint, not dropped
  run jq -r '.classes[0].occurrences[] | select(.path=="b.py") | .last_seen_sprint' "$LEDGER"
  [ "$output" = "sprint-001" ]
  run jq -r '.classes[0].occurrences[] | select(.path=="c.py") | .first_seen_sprint' "$LEDGER"
  [ "$output" = "sprint-003" ]
}

@test "add-occurrences: --replace drops entries absent from the input" {
  _seed_class
  cat > occ1.json <<'EOF'
[{"path":"a.py"},{"path":"b.py"}]
EOF
  "$W" add-occurrences --identity "$K" --sprint sprint-001 --from occ1.json >/dev/null
  cat > occ2.json <<'EOF'
[{"path":"a.py"}]
EOF
  run "$W" add-occurrences --identity "$K" --sprint sprint-002 --from occ2.json --replace
  [ "$status" -eq 0 ]
  run jq -c '[.classes[0].occurrences[].path]' "$LEDGER"
  [ "$output" = '["a.py"]' ]
}

@test "add-occurrences: rejects a malformed input file and a missing one" {
  _seed_class
  echo '{"path":"a.py"}' > bad1.json
  run "$W" add-occurrences --identity "$K" --sprint sprint-001 --from bad1.json
  [ "$status" -eq 64 ]
  echo '[{"path":""}]' > bad2.json
  run "$W" add-occurrences --identity "$K" --sprint sprint-001 --from bad2.json
  [ "$status" -eq 64 ]
  echo '[{"path":"a.py","bogus":1}]' > bad3.json
  run "$W" add-occurrences --identity "$K" --sprint sprint-001 --from bad3.json
  [ "$status" -eq 64 ]
  run "$W" add-occurrences --identity "$K" --sprint sprint-001 --from nope.json
  [ "$status" -eq 67 ]
}

# --- link-pbi (invariant 9) -------------------------------------------------

@test "link-pbi: refuses a pbi absent from the backlog, accepts one present, upserts on id" {
  _seed_class
  run "$W" link-pbi --identity "$K" --pbi pbi-999 --role sweep
  [ "$status" -eq 64 ]
  [[ "$output" == *"not in .scrum/backlog.json"* ]]
  run "$W" link-pbi --identity "$K" --pbi pbi-001 --role sweep
  [ "$status" -eq 0 ]
  run "$W" link-pbi --identity "$K" --pbi pbi-001 --role detector
  [ "$status" -eq 0 ]
  run jq -c '.classes[0].pbi_ids' "$LEDGER"
  [ "$output" = '[{"id":"pbi-001","role":"detector"}]' ]
}

@test "link-pbi: rejects a role outside the schema enum" {
  _seed_class
  run "$W" link-pbi --identity "$K" --pbi pbi-001 --role reviewer
  [ "$status" -eq 64 ]
}

# --- set-status sweeping (invariant 7) --------------------------------------

@test "set-status sweeping: refused with no open linked PBI, allowed with one" {
  _seed_class
  run "$W" set-status --identity "$K" --status sweeping
  [ "$status" -eq 64 ]
  _link_pbi_with_status done
  run "$W" set-status --identity "$K" --status sweeping
  [ "$status" -eq 64 ]
  jq '.items[0].status = "refined"' .scrum/backlog.json > b.tmp && mv b.tmp .scrum/backlog.json
  run "$W" set-status --identity "$K" --status sweeping
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "sweeping" ]
}

# --- set-status guarded (invariant 4) ---------------------------------------

@test "set-status guarded: refused when no detector is registered" {
  _seed_class
  _wire_merge
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 64 ]
  [[ "$output" == *"no detector registered"* ]]
}

@test "set-status guarded: refused when the deployed merge-pbi.sh does not call run-detectors.sh" {
  _seed_class
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'grep -rq FORBIDDEN . && exit 1' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 64 ]
  [[ "$output" == *"does not invoke run-detectors.sh"* ]]
  [[ "$output" == *"setup-user.sh"* ]]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "set-status guarded: refused when --check exits 2 (the detector did not execute)" {
  _seed_class
  _wire_merge
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner2.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 64 ]
  [[ "$output" == *"exited 2"* ]]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "set-status guarded: refused when the runner is not deployed, naming setup-user.sh" {
  _seed_class
  _wire_merge
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/absent-runner.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 64 ]
  [[ "$output" == *"setup-user.sh"* ]]
}

@test "set-status guarded: succeeds when all four preconditions hold and re-stamps the verification" {
  _seed_class
  _wire_merge
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  # exit 1 (violations) still counts as EXECUTED — "wired" is the check here,
  # not "clean".
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner1.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 0 ]
  run jq -r '.classes[0] | "\(.status)|\(.detector.verified_exit)"' "$LEDGER"
  [ "$output" = "guarded|1" ]
  run jq -e '.classes[0].detector.verified_at | test("^[0-9]{4}-")' "$LEDGER"
  [ "$status" -eq 0 ]
}

# --- set-status accepted (invariant 5) --------------------------------------

@test "set-status accepted: refused with no --dec-id, an unknown id, or a non-suppression kind" {
  _seed_class
  run "$W" set-status --identity "$K" --status accepted
  [ "$status" -eq 64 ]
  [[ "$output" == *"--dec-id"* ]]
  _seed_decisions
  run "$W" set-status --identity "$K" --status accepted --dec-id dec-0099
  [ "$status" -eq 64 ]
  [[ "$output" == *"not found"* ]]
  run "$W" set-status --identity "$K" --status accepted --dec-id dec-0002
  [ "$status" -eq 64 ]
  [[ "$output" == *"sprint_goal_approval"* ]]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "set-status accepted: refused when the decisions log does not exist" {
  _seed_class
  run "$W" set-status --identity "$K" --status accepted --dec-id dec-0001
  [ "$status" -eq 64 ]
  [[ "$output" == *"cannot be verified"* ]]
}

@test "set-status accepted: allowed for defect_triage and spec_clarification" {
  _seed_class
  _seed_decisions
  run "$W" set-status --identity "$K" --status accepted --dec-id dec-0001
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "accepted" ]
  run "$W" set-status --identity "$K" --status open
  [ "$status" -eq 0 ]
  run "$W" set-status --identity "$K" --status accepted --dec-id dec-0003
  [ "$status" -eq 0 ]
}

# --- add-exclusion (invariant 8) --------------------------------------------

@test "add-exclusion: refused on an unknown dec_id and on a malformed one" {
  _seed_class
  _seed_decisions
  run "$W" add-exclusion --identity "$K" --path a.py --reason "generated code" --dec-id dec-0099
  [ "$status" -eq 64 ]
  run "$W" add-exclusion --identity "$K" --path a.py --reason "generated code" --dec-id dec-1
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --dec-id"* ]]
  run jq -r '.classes[0].exclusions | length' "$LEDGER"
  [ "$output" = "0" ]
}

@test "add-exclusion: records the waiver and upserts on (path, symbol)" {
  _seed_class
  _seed_decisions
  run "$W" add-exclusion --identity "$K" --path a.py --symbol f --reason "generated code" --dec-id dec-0001
  [ "$status" -eq 0 ]
  run "$W" add-exclusion --identity "$K" --path a.py --symbol f --reason "still generated" --dec-id dec-0003 --round r2
  [ "$status" -eq 0 ]
  run "$W" add-exclusion --identity "$K" --path a.py --reason "whole file" --dec-id dec-0001
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].exclusions | length' "$LEDGER"
  [ "$output" = "2" ]
  run jq -r '.classes[0].exclusions[] | select(.symbol=="f") | "\(.reason)|\(.dec_id)|\(.round)"' "$LEDGER"
  [ "$output" = "still generated|dec-0003|r2" ]
}

@test "add-exclusion: --path and --reason are required" {
  _seed_class
  _seed_decisions
  run "$W" add-exclusion --identity "$K" --reason x --dec-id dec-0001
  [ "$status" -eq 64 ]
  run "$W" add-exclusion --identity "$K" --path a.py --dec-id dec-0001
  [ "$status" -eq 64 ]
}

# --- set-status closed (invariant 6) ----------------------------------------

@test "set-status closed: refused with no done PBI" {
  _seed_class
  run "$W" set-status --identity "$K" --status closed --evidence "rg -n pattern | wc -l == 0"
  [ "$status" -eq 64 ]
  [[ "$output" == *"no linked PBI is done"* ]]
  _link_pbi_with_status refined
  run "$W" set-status --identity "$K" --status closed --evidence "rg -n pattern | wc -l == 0"
  [ "$status" -eq 64 ]
}

@test "set-status closed: refused with neither a clean detector nor --evidence" {
  _seed_class
  _link_pbi_with_status done
  run "$W" set-status --identity "$K" --status closed
  [ "$status" -eq 64 ]
  [[ "$output" == *"no --evidence and no registered detector"* ]]
  # A detector that reports violations does not close the class either.
  _wire_merge
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner1.sh" "$W" set-status --identity "$K" --status closed
  [ "$status" -eq 64 ]
  [[ "$output" == *"exited 1"* ]]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "set-status closed: --evidence records the re-runnable zero-check" {
  _seed_class
  _link_pbi_with_status done
  run "$W" set-status --identity "$K" --status closed --evidence "rg -n 'send-before-write' | wc -l == 0"
  [ "$status" -eq 0 ]
  run jq -r '.classes[0] | "\(.status)|\(.closed_evidence)"' "$LEDGER"
  [ "$output" = "closed|rg -n 'send-before-write' | wc -l == 0" ]
}

@test "set-status closed: a clean detector run closes the class without --evidence" {
  _seed_class
  _link_pbi_with_status done
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" set-status --identity "$K" --status closed
  [ "$status" -eq 0 ]
  run jq -r '.classes[0] | "\(.status)|\(.detector.verified_exit)"' "$LEDGER"
  [ "$output" = "closed|0" ]
}

@test "set-status: rejects a status outside the schema enum" {
  _seed_class
  run "$W" set-status --identity "$K" --status resolved
  [ "$status" -eq 64 ]
}

# --- register-detector (invariant 10) ---------------------------------------

@test "register-detector: a command that cannot execute is refused and rolled back" {
  _seed_class
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner2.sh" "$W" register-detector \
    --identity "$K" --command 'no-such-binary --check' --sprint sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"rolled back"* ]]
  run jq -r '.classes[0].detector' "$LEDGER"
  [ "$output" = "null" ]
}

@test "register-detector: a runner usage error (exit 64) is refused and rolled back too" {
  # 64 is the runner's "unknown identity / bad usage" code. It is not 0 or 1,
  # so the detector did not run — treating it as anything but a refusal would
  # register a command nobody ever executed.
  _seed_class
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner64.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"rolled back"* ]]
  run jq -r '.classes[0].detector' "$LEDGER"
  [ "$output" = "null" ]
}

@test "register-detector: a previously registered detector is restored, not erased, on a failed re-register" {
  _seed_class
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'first-command' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner2.sh" "$W" register-detector \
    --identity "$K" --command 'second-command' --sprint sprint-002
  [ "$status" -eq 64 ]
  run jq -r '.classes[0].detector | "\(.command)|\(.registered_sprint)|\(.verified_exit)"' "$LEDGER"
  [ "$output" = "first-command|sprint-001|0" ]
}

@test "set-status guarded: a runner usage error (exit 64) is refused" {
  _seed_class
  _wire_merge
  env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector \
    --identity "$K" --command 'true' --sprint sprint-001 >/dev/null
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner64.sh" "$W" set-status --identity "$K" --status guarded
  [ "$status" -eq 64 ]
  [[ "$output" == *"exited 64"* ]]
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "register-detector: stores the command with its own verification stamp, status untouched" {
  _seed_class
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner1.sh" "$W" register-detector \
    --identity "$K" --command 'grep -rq FORBIDDEN src/' --sprint sprint-002 \
    --scope-caveat 'misses dynamic dispatch'
  [ "$status" -eq 0 ]
  run jq -r '.classes[0].detector | "\(.command)|\(.registered_sprint)|\(.verified_exit)|\(.scope_caveat)"' "$LEDGER"
  [ "$output" = "grep -rq FORBIDDEN src/|sprint-002|1|misses dynamic dispatch" ]
  # Promotion is a separate, separately-auditable call.
  run jq -r '.classes[0].status' "$LEDGER"
  [ "$output" = "open" ]
}

@test "register-detector: --command and --sprint are required" {
  _seed_class
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector --identity "$K" --sprint sprint-001
  [ "$status" -eq 64 ]
  run env SCRUM_RUN_DETECTORS="$TEST_TMP/runner0.sh" "$W" register-detector --identity "$K" --command 'true'
  [ "$status" -eq 64 ]
}

# --- confirm-seen -----------------------------------------------------------

@test "confirm-seen: moves only last_confirmed_sprint" {
  _seed_class
  run "$W" confirm-seen --identity "$K" --sprint sprint-009
  [ "$status" -eq 0 ]
  run jq -r '.classes[0] | "\(.first_seen_sprint)|\(.last_confirmed_sprint)|\(.status)"' "$LEDGER"
  [ "$output" = "sprint-001|sprint-009|open" ]
}

# --- list (read-only) -------------------------------------------------------

@test "list: an absent ledger is an empty ledger, and list never creates one" {
  run "$W" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$LEDGER" ]
  run "$W" list --format json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -f "$LEDGER" ]
}

@test "list: tsv and json render the classes, --status filters" {
  _seed_class
  "$W" upsert-class --identity other-class::other-pattern --sprint sprint-002 --severity low >/dev/null
  _seed_decisions
  "$W" set-status --identity other-class::other-pattern --status accepted --dec-id dec-0001 >/dev/null
  run "$W" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" = "2" ]
  [[ "$output" == *"$K"* ]]
  run "$W" list --status accepted
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]
  [[ "$output" == *"other-class::other-pattern"* ]]
  run "$W" list --format json --status open
  [ "$status" -eq 0 ]
  run bash -c "'$W' list --format json --status open | jq -r '.[0].identity'"
  [ "$output" = "$K" ]
}

@test "list: rejects a bad --format and a bad --status" {
  run "$W" list --format yaml
  [ "$status" -eq 64 ]
  run "$W" list --status bogus
  [ "$status" -eq 64 ]
}

# --- CLI surface ------------------------------------------------------------

@test "usage: --help exits 0, a missing or unknown subcommand and an unknown flag exit 64" {
  run "$W" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"upsert-class"* ]]
  run "$W"
  [ "$status" -eq 64 ]
  run "$W" frobnicate --identity "$K"
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown subcommand"* ]]
  run "$W" upsert-class --identity "$K" --sprint sprint-001 --bogus x
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}

# --- concurrency ------------------------------------------------------------

@test "concurrent upsert-class calls serialize under the directory lock" {
  _seed_class
  local i
  for i in 1 2 3 4 5; do
    "$W" upsert-class --identity "klass-${i}::pattern-${i}" --sprint sprint-001 >/dev/null &
  done
  wait
  run jq '.classes | length' "$LEDGER"
  [ "$output" = "6" ]
}
