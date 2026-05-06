# PBI Worktree + Merge Governance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define and enforce a single git workflow for PBI development (per-PBI worktree + branch, immediate per-PBI merge by SM, artifact-existence verification gate) so that completed PBI artifacts can never silently disappear between Sprints.

**Architecture:** Each PBI gets its own `git worktree add` at `.scrum/worktrees/<pbi-id>` checked out at branch `pbi/<pbi-id>` forked from `sprint.base_sha`. A `.scrum` symlink in each worktree shares the SSOT with the main worktree, preserving existing `$PWD/.scrum/...` access. On PBI completion the Developer hands off (`phase=ready_to_merge`); SM runs `pbi-merge` skill, which performs `--no-ff` merge into main, verifies every `paths_touched` file is on HEAD, runs the existing `quality-gate.sh`, and only then sets `phase=merged`. Failures mark `merge_conflict` / `merge_artifact_missing` / `merge_regression` and roll back; three consecutive failures escalate via `pbi-escalation-handler`.

**Tech Stack:** Bash 3.2+, jq, git worktrees, bats-core test framework, JSON Schema Draft-07 (validated through existing `lib/atomic.sh` + `SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli`).

**Reference spec:** `docs/superpowers/specs/2026-05-04-pbi-worktree-merge-governance-design.md`

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `scripts/scrum/freeze-sprint-base.sh` | Capture `sprint.base_sha` once at Sprint start |
| `scripts/scrum/create-pbi-worktree.sh` | Create `git worktree` + `pbi/<id>` branch + symlink, populate state |
| `scripts/scrum/commit-pbi.sh` | Single-call commit wrapper used by Developer / sub-agents; refuses if checked-out branch is not `pbi/<id>` |
| `scripts/scrum/mark-pbi-ready-to-merge.sh` | Set `phase=ready_to_merge` + `head_sha` + `paths_touched` + `ready_at` atomically |
| `scripts/scrum/mark-pbi-merged.sh` | Set `phase=merged` + `merged_sha` + `merged_at`; mirror to backlog |
| `scripts/scrum/mark-pbi-merge-failure.sh` | Set `phase ∈ merge_*` + `merge_failure` + bump `merge_failure_count`; promote to `escalated` on 3rd consecutive |
| `scripts/scrum/cleanup-pbi-worktree.sh` | Idempotent removal of worktree + branch (post-merge) |
| `scripts/scrum/merge-pbi.sh` | SM-side orchestrator: pre-check → `--no-ff` merge → verify → record → cleanup |
| `hooks/pre-tool-use-no-branch-ops.sh` | Bash-tool guard against `git checkout -b` / `switch -c` / `branch <new>` / `push` / `merge` / `rebase` outside `.scrum/scripts/*` |
| `skills/pbi-merge/SKILL.md` | SM skill triggered by `[<pbi-id>] PBI_READY_TO_MERGE`; calls `merge-pbi.sh` |
| `tests/unit/scrum-state/test_freeze-sprint-base.bats` | Tests for B1 |
| `tests/unit/scrum-state/test_create-pbi-worktree.bats` | Tests for B2 |
| `tests/unit/scrum-state/test_commit-pbi.bats` | Tests for B3 |
| `tests/unit/scrum-state/test_mark-pbi-ready-to-merge.bats` | Tests for B4 |
| `tests/unit/scrum-state/test_mark-pbi-merged.bats` | Tests for B5 |
| `tests/unit/scrum-state/test_mark-pbi-merge-failure.bats` | Tests for B6 |
| `tests/unit/scrum-state/test_cleanup-pbi-worktree.bats` | Tests for B7 |
| `tests/unit/scrum-state/test_merge-pbi.bats` | Tests for B8 |
| `tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats` | Tests for C1 |

### Modified files

| Path | Change |
|---|---|
| `docs/contracts/scrum-state/pbi-state.schema.json` | Phase enum + new fields |
| `docs/contracts/scrum-state/backlog.schema.json` | `merged_sha`, `merged_at` on item |
| `docs/contracts/scrum-state/sprint.schema.json` | `base_sha`, `base_sha_captured_at` |
| `scripts/scrum/lib/derive.sh` | Phase→status table for new phases |
| `scripts/scrum/update-pbi-state.sh` | New phase enum values + new scalar field whitelist |
| `tests/unit/scrum-state/test_derive.bats` | Cover new phases |
| `tests/unit/scrum-state/test_update-pbi-state.bats` | Cover new phases + scalars |
| `agents/developer.md` | Strict Rules + State Files |
| `agents/scrum-master.md` | Allowed list + Workflow + skills |
| `skills/spawn-teammates/SKILL.md` | Step 0 + 5.5 + task-prompt update |
| `skills/pbi-pipeline/SKILL.md` | Outputs + Phases + Exit Criteria |
| `skills/pbi-pipeline/references/state-management.md` | New schema + projection |
| `skills/cross-review/SKILL.md` | Precondition (`merged | escalated`) |
| `skills/sprint-planning/SKILL.md` | Brief note about per-PBI worktree isolation |
| `scripts/setup-user.sh` | Deploy new wrappers + register new hook |
| `docs/MIGRATION-scrum-state-tools.md` | New wrapper map entries |
| `CLAUDE.md` | Git Workflow section + State management additions |

### Untouched

- `hooks/quality-gate.sh` (already correctly scopes via `git merge-base`)
- `hooks/pre-tool-use-scrum-state-guard.sh` (existing pattern still covers new state writes — verified during A1)

---

## Build Order

A → B → C → D → E → F. Within each phase, tasks may be done in declared order. Each task ends in a commit so progress is recoverable.

---

## Phase A: Foundation (schemas + projection + base setter)

### Task A1: Extend pbi-state.schema.json with new phases and fields

**Files:**
- Modify: `docs/contracts/scrum-state/pbi-state.schema.json`
- Test: `tests/unit/scrum-state/test_update-pbi-state.bats` (existing — no edit yet)

- [ ] **Step 1: Read the current schema**

```bash
cat docs/contracts/scrum-state/pbi-state.schema.json
```

- [ ] **Step 2: Edit the schema**

Apply the following changes:

1. Replace the `phase` enum line with the extended set.

   Find:
   ```
   "phase": {"enum": ["design", "impl_ut", "complete", "review_complete", "escalated"]},
   ```
   Replace with:
   ```
   "phase": {"enum": [
     "design", "impl_ut", "complete",
     "ready_to_merge", "merged",
     "merge_conflict", "merge_artifact_missing", "merge_regression",
     "review_complete", "escalated"
   ]},
   ```

2. Add the following property definitions inside `properties` (before `started_at`):

   ```json
   "branch":             {"type": "string", "pattern": "^pbi/pbi-[0-9]+$"},
   "worktree":           {"type": "string", "pattern": "^\\.scrum/worktrees/pbi-[0-9]+$"},
   "base_sha":           {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
   "head_sha":           {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
   "paths_touched":      {"type": "array", "items": {"type": "string"}, "uniqueItems": true},
   "ready_at":           {"type": "string", "format": "date-time"},
   "merged_sha":         {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
   "merged_at":          {"type": "string", "format": "date-time"},
   "merge_failure": {
     "type": "object",
     "additionalProperties": false,
     "required": ["kind", "pre_head_at_failure"],
     "properties": {
       "kind":                {"enum": ["conflict", "artifact_missing", "regression"]},
       "paths":               {"type": "array", "items": {"type": "string"}},
       "report_path":         {"type": "string"},
       "pre_head_at_failure": {"type": "string", "pattern": "^[0-9a-f]{7,40}$"}
     }
   },
   "merge_failure_count": {"type": "integer", "minimum": 0},
   ```

- [ ] **Step 3: Run existing pbi-state tests to confirm schema still parses**

```bash
bats tests/unit/scrum-state/test_update-pbi-state.bats
```
Expected: all existing tests still PASS (the schema change is additive — no existing fields removed; phase enum is a superset).

- [ ] **Step 4: Commit**

```bash
git add docs/contracts/scrum-state/pbi-state.schema.json
git commit -m "feat(scrum-state): extend pbi-state phase enum + add merge fields

Adds ready_to_merge, merged, merge_conflict, merge_artifact_missing,
merge_regression to the phase enum, plus the supporting fields
required by the worktree/merge governance design."
```

---

### Task A2: Extend backlog.schema.json with merged_sha + merged_at

**Files:**
- Modify: `docs/contracts/scrum-state/backlog.schema.json`

- [ ] **Step 1: Edit the schema**

In the items[] property block, after `updated_at`, add:

```json
"merged_sha": {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
"merged_at":  {"type": "string", "format": "date-time"},
```

- [ ] **Step 2: Run backlog tests**

```bash
bats tests/unit/scrum-state/test_update-backlog-status.bats tests/unit/scrum-state/test_add-backlog-item.bats
```
Expected: PASS (additive change).

- [ ] **Step 3: Commit**

```bash
git add docs/contracts/scrum-state/backlog.schema.json
git commit -m "feat(scrum-state): add merged_sha + merged_at to backlog item schema"
```

---

### Task A3: Extend sprint.schema.json with base_sha

**Files:**
- Modify: `docs/contracts/scrum-state/sprint.schema.json`

- [ ] **Step 1: Edit the schema**

In `properties`, after `goal`, add:

```json
"base_sha":             {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
"base_sha_captured_at": {"type": "string", "format": "date-time"},
```

- [ ] **Step 2: Run sprint tests**

```bash
bats tests/unit/scrum-state/test_update-sprint-status.bats tests/unit/scrum-state/test_set-sprint-developer.bats
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add docs/contracts/scrum-state/sprint.schema.json
git commit -m "feat(scrum-state): add base_sha + base_sha_captured_at to sprint schema"
```

---

### Task A4: Update derive.sh phase→status table

**Files:**
- Modify: `scripts/scrum/lib/derive.sh`
- Test: `tests/unit/scrum-state/test_derive.bats`

- [ ] **Step 1: Add failing tests**

Append to `tests/unit/scrum-state/test_derive.bats`:

```bash
@test "derive: ready_to_merge → review" {
  run bash -c "source $PROJECT_ROOT/scripts/scrum/lib/derive.sh && derive_backlog_status_from_phase ready_to_merge"
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "derive: merged → review" {
  run bash -c "source $PROJECT_ROOT/scripts/scrum/lib/derive.sh && derive_backlog_status_from_phase merged"
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "derive: merge_conflict → review" {
  run bash -c "source $PROJECT_ROOT/scripts/scrum/lib/derive.sh && derive_backlog_status_from_phase merge_conflict"
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "derive: merge_artifact_missing → review" {
  run bash -c "source $PROJECT_ROOT/scripts/scrum/lib/derive.sh && derive_backlog_status_from_phase merge_artifact_missing"
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "derive: merge_regression → review" {
  run bash -c "source $PROJECT_ROOT/scripts/scrum/lib/derive.sh && derive_backlog_status_from_phase merge_regression"
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}
```

(If the file does not already define `PROJECT_ROOT`, copy the `setup()` pattern from `tests/unit/scrum-state/test_update-pbi-state.bats`.)

- [ ] **Step 2: Run the new tests**

```bash
bats tests/unit/scrum-state/test_derive.bats
```
Expected: 5 new tests FAIL with non-zero exit (unknown phase).

- [ ] **Step 3: Update derive.sh**

In `scripts/scrum/lib/derive.sh`, replace the `case "$1" in` block of `derive_backlog_status_from_phase` with:

```bash
  case "$1" in
    design)                 echo "in_progress" ;;
    impl_ut)                echo "in_progress" ;;
    complete)               echo "review" ;;
    ready_to_merge)         echo "review" ;;
    merged)                 echo "review" ;;
    merge_conflict)         echo "review" ;;
    merge_artifact_missing) echo "review" ;;
    merge_regression)       echo "review" ;;
    review_complete)        echo "done" ;;
    escalated)              echo "blocked" ;;
    *) return 1 ;;
  esac
```

- [ ] **Step 4: Run all derive tests**

```bash
bats tests/unit/scrum-state/test_derive.bats
```
Expected: all PASS (existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/lib/derive.sh tests/unit/scrum-state/test_derive.bats
git commit -m "feat(scrum-state): project new merge phases to backlog status \"review\"

ready_to_merge / merged / merge_conflict / merge_artifact_missing /
merge_regression all map to backlog status \"review\" — the PBI is
out of the developer's hands but not yet accepted by cross-review."
```

---

### Task A5: Extend update-pbi-state.sh field whitelist

**Files:**
- Modify: `scripts/scrum/update-pbi-state.sh`
- Test: `tests/unit/scrum-state/test_update-pbi-state.bats`

`update-pbi-state.sh` is a flat-key=value setter. We extend it for the new scalar fields and accept the new phase enum values. Complex fields (`paths_touched`, `merge_failure`) get dedicated wrappers in Phase B.

- [ ] **Step 1: Add failing tests**

Append to `tests/unit/scrum-state/test_update-pbi-state.bats`:

```bash
@test "update-pbi-state: accepts ready_to_merge phase" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase ready_to_merge
  [ "$status" -eq 0 ]
  run jq -r '.phase' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "ready_to_merge" ]
}

@test "update-pbi-state: accepts merged phase" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase merged
  [ "$status" -eq 0 ]
}

@test "update-pbi-state: accepts merge_conflict / merge_artifact_missing / merge_regression" {
  for p in merge_conflict merge_artifact_missing merge_regression; do
    run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 phase "$p"
    [ "$status" -eq 0 ]
  done
}

@test "update-pbi-state: sets branch / worktree / base_sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" \
    pbi-001 branch pbi/pbi-001 worktree .scrum/worktrees/pbi-001 base_sha abcdef0123456789
  [ "$status" -eq 0 ]
  run jq -r '"\(.branch)|\(.worktree)|\(.base_sha)"' "$TEST_TMP/.scrum/pbi/pbi-001/state.json"
  [ "$output" = "pbi/pbi-001|.scrum/worktrees/pbi-001|abcdef0123456789" ]
}

@test "update-pbi-state: sets head_sha / merged_sha / merge_failure_count" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" \
    pbi-001 head_sha 1234567 merged_sha abcdef0 merge_failure_count 2
  [ "$status" -eq 0 ]
}

@test "update-pbi-state: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 head_sha NOT_A_SHA
  [ "$status" -ne 0 ]
}

@test "update-pbi-state: rejects bad branch name" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/update-pbi-state.sh" pbi-001 branch main
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run new tests**

```bash
bats tests/unit/scrum-state/test_update-pbi-state.bats
```
Expected: 7 new tests FAIL.

- [ ] **Step 3: Update update-pbi-state.sh**

In the `case "$F"` block of `update-pbi-state.sh`:

(a) Replace the `phase` arm value-check with the extended enum:
```bash
    phase)
      case "$V" in
        design|impl_ut|complete|ready_to_merge|merged|merge_conflict|merge_artifact_missing|merge_regression|review_complete|escalated) ;;
        *) fail E_INVALID_ARG "bad phase: $V" ;;
      esac
      EXPR="$EXPR | .phase = \"$V\""
      NEW_PHASE="$V"
      ;;
```

(b) Before the final `*)` arm (unknown field), insert the following arms:

```bash
    branch)
      case "$V" in
        pbi/pbi-[0-9]*) ;;
        *) fail E_INVALID_ARG "bad branch (must be pbi/pbi-NNN): $V" ;;
      esac
      EXPR="$EXPR | .branch = \"$V\""
      ;;
    worktree)
      case "$V" in
        .scrum/worktrees/pbi-[0-9]*) ;;
        *) fail E_INVALID_ARG "bad worktree (must be .scrum/worktrees/pbi-NNN): $V" ;;
      esac
      EXPR="$EXPR | .worktree = \"$V\""
      ;;
    base_sha|head_sha|merged_sha)
      case "$V" in
        [0-9a-f]*) [ ${#V} -ge 7 ] && [ ${#V} -le 40 ] || fail E_INVALID_ARG "$F length must be 7..40: $V" ;;
        *) fail E_INVALID_ARG "$F must be hex sha: $V" ;;
      esac
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    ready_at|merged_at)
      # ISO-8601 sanity (full validation is left to the schema validator)
      case "$V" in
        [0-9][0-9][0-9][0-9]-*) ;;
        *) fail E_INVALID_ARG "$F must be ISO-8601: $V" ;;
      esac
      EXPR="$EXPR | .$F = \"$V\""
      ;;
    merge_failure_count)
      case "$V" in
        ''|*[!0-9]*) fail E_INVALID_ARG "merge_failure_count must be non-negative integer (got: $V)" ;;
      esac
      EXPR="$EXPR | .merge_failure_count = $V"
      ;;
```

Also update the docstring header (the `Writable fields:` block) to list the new fields.

- [ ] **Step 4: Run all tests**

```bash
bats tests/unit/scrum-state/test_update-pbi-state.bats
bats tests/unit/scrum-state/test_update-pbi-state-projection.bats
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/update-pbi-state.sh tests/unit/scrum-state/test_update-pbi-state.bats
git commit -m "feat(scrum-state): allow merge phases + worktree/sha fields via update-pbi-state"
```

---

## Phase B: Wrappers

### Task B1: freeze-sprint-base.sh

**Files:**
- Create: `scripts/scrum/freeze-sprint-base.sh`
- Test: `tests/unit/scrum-state/test_freeze-sprint-base.bats`

- [ ] **Step 1: Write failing test**

```bash
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
```

Save as `tests/unit/scrum-state/test_freeze-sprint-base.bats`.

- [ ] **Step 2: Run, expect fail (script missing)**

```bash
bats tests/unit/scrum-state/test_freeze-sprint-base.bats
```
Expected: 3 tests FAIL because the script does not exist.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/freeze-sprint-base.sh — capture sprint.base_sha once at Sprint start.
# Idempotency: refuses to overwrite a non-null base_sha (call exactly once per Sprint).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

SPRINT=".scrum/sprint.json"
SCHEMA="$ROOT/docs/contracts/scrum-state/sprint.schema.json"
[ -f "$SPRINT" ] || fail E_FILE_MISSING "$SPRINT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail E_INVALID_ARG "freeze-sprint-base: not inside a git repo"

if jq -e 'has("base_sha") and .base_sha != null and .base_sha != ""' "$SPRINT" >/dev/null 2>&1; then
  fail E_INVALID_ARG "sprint.base_sha already frozen — call exactly once per Sprint"
fi

SHA="$(git rev-parse HEAD)"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

atomic_write "$SPRINT" \
  ".base_sha = \"$SHA\" | .base_sha_captured_at = \"$NOW\"" \
  "$SCHEMA"
printf '[freeze-sprint-base] frozen at %s (%s)\n' "$SHA" "$NOW"
```

Save as `scripts/scrum/freeze-sprint-base.sh` and `chmod +x` it.

- [ ] **Step 4: Run tests**

```bash
chmod +x scripts/scrum/freeze-sprint-base.sh
bats tests/unit/scrum-state/test_freeze-sprint-base.bats
```
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/freeze-sprint-base.sh tests/unit/scrum-state/test_freeze-sprint-base.bats
git commit -m "feat(scrum-state): add freeze-sprint-base.sh wrapper"
```

---

### Task B2: create-pbi-worktree.sh

**Files:**
- Create: `scripts/scrum/create-pbi-worktree.sh`
- Test: `tests/unit/scrum-state/test_create-pbi-worktree.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/create-pbi-worktree.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/create-pbi-worktree.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  git init -q
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"design","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
}

teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "create-pbi-worktree: creates worktree, branch, symlink, and updates state" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
  [ -d .scrum/worktrees/pbi-001 ]
  [ -L .scrum/worktrees/pbi-001/.scrum ]
  run git -C .scrum/worktrees/pbi-001 rev-parse --abbrev-ref HEAD
  [ "$output" = "pbi/pbi-001" ]
  run jq -r '"\(.branch)|\(.worktree)|\(.base_sha)"' .scrum/pbi/pbi-001/state.json
  SHA="$(git rev-parse HEAD)"
  [ "$output" = "pbi/pbi-001|.scrum/worktrees/pbi-001|$SHA" ]
}

@test "create-pbi-worktree: refuses if sprint.base_sha is missing" {
  jq 'del(.base_sha)' .scrum/sprint.json > .scrum/sprint.json.tmp && mv .scrum/sprint.json.tmp .scrum/sprint.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -ne 0 ]
}

@test "create-pbi-worktree: refuses if pbi state missing" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-999
  [ "$status" -ne 0 ]
}

@test "create-pbi-worktree: idempotent — second call no-ops cleanly" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_create-pbi-worktree.bats
```
Expected: tests FAIL (script missing).

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/create-pbi-worktree.sh — create per-PBI git worktree + branch + symlink.
# Records branch/worktree/base_sha in pbi state.json. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: create-pbi-worktree.sh <pbi-id>"
PBI="$1"
case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac

SPRINT=".scrum/sprint.json"
STATE=".scrum/pbi/$PBI/state.json"
[ -f "$SPRINT" ] || fail E_FILE_MISSING "$SPRINT"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

BASE="$(jq -r '.base_sha // ""' "$SPRINT")"
[ -n "$BASE" ] || fail E_INVALID_ARG "sprint.base_sha is empty — run freeze-sprint-base.sh first"

WT=".scrum/worktrees/$PBI"
BRANCH="pbi/$PBI"

# Idempotent: if worktree exists and branch checked out matches, just sync state.
if [ -d "$WT" ]; then
  cur="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" = "$BRANCH" ]; then
    printf '[create-pbi-worktree] %s already exists, syncing state\n' "$WT"
  else
    fail E_INVALID_ARG "$WT exists but checked out branch is '$cur' (expected $BRANCH)"
  fi
else
  git worktree add -b "$BRANCH" "$WT" "$BASE" >/dev/null
fi

# Symlink .scrum/ in the worktree (relative, three levels up)
if [ ! -L "$WT/.scrum" ]; then
  (cd "$WT" && ln -s ../../../.scrum .scrum)
fi

# Sync pbi state. Use update-pbi-state.sh for schema-validated writes.
"$HERE/update-pbi-state.sh" "$PBI" \
  branch "$BRANCH" \
  worktree "$WT" \
  base_sha "$BASE"

printf '[create-pbi-worktree] ready: %s @ %s (branch %s)\n' "$WT" "$BASE" "$BRANCH"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/create-pbi-worktree.sh
bats tests/unit/scrum-state/test_create-pbi-worktree.bats
```
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/create-pbi-worktree.sh tests/unit/scrum-state/test_create-pbi-worktree.bats
git commit -m "feat(scrum-state): add create-pbi-worktree.sh wrapper"
```

---

### Task B3: commit-pbi.sh

**Files:**
- Create: `scripts/scrum/commit-pbi.sh`
- Test: `tests/unit/scrum-state/test_commit-pbi.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/commit-pbi.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/commit-pbi.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/sprint.schema.json" docs/contracts/scrum-state/
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/pbi-state.schema.json" docs/contracts/scrum-state/
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"impl_ut","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "commit-pbi: commits and updates head_sha" {
  echo "hello" > .scrum/worktrees/pbi-001/file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: add file"
  [ "$status" -eq 0 ]
  EXPECTED="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  run jq -r '.head_sha' .scrum/pbi/pbi-001/state.json
  [ "$output" = "$EXPECTED" ]
}

@test "commit-pbi: refuses if branch is not pbi/<id>" {
  git -C .scrum/worktrees/pbi-001 checkout -b rogue
  echo "x" > .scrum/worktrees/pbi-001/file.txt
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "msg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "branch"
}

@test "commit-pbi: noops cleanly when nothing to commit" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "msg"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_commit-pbi.bats
```
Expected: FAIL (script missing).

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/commit-pbi.sh — Developer-side commit wrapper for the PBI worktree.
# Verifies branch == pbi/<id> before committing. Updates state.head_sha after.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: commit-pbi.sh <pbi-id> <message>"
PBI="$1"; MSG="$2"
case "$PBI" in
  pbi-[0-9]*) ;;
  *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;;
esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
WT="$(jq -r '.worktree // ""' "$STATE")"
EXPECTED_BRANCH="$(jq -r '.branch // ""' "$STATE")"
[ -n "$WT" ] && [ -d "$WT" ] || fail E_FILE_MISSING "PBI worktree missing: $WT"
[ -n "$EXPECTED_BRANCH" ] || fail E_INVALID_ARG "state.branch unset for $PBI"

CUR_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
if [ "$CUR_BRANCH" != "$EXPECTED_BRANCH" ]; then
  fail E_INVALID_ARG "worktree on wrong branch: have=$CUR_BRANCH expected=$EXPECTED_BRANCH"
fi

git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  printf '[commit-pbi] nothing to commit\n'
  exit 0
fi
git -C "$WT" commit -m "$MSG" >/dev/null

NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
"$HERE/update-pbi-state.sh" "$PBI" head_sha "$NEW_HEAD"
printf '[commit-pbi] %s @ %s\n' "$PBI" "$NEW_HEAD"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/commit-pbi.sh
bats tests/unit/scrum-state/test_commit-pbi.bats
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/commit-pbi.sh tests/unit/scrum-state/test_commit-pbi.bats
git commit -m "feat(scrum-state): add commit-pbi.sh wrapper with branch guard"
```

---

### Task B4: mark-pbi-ready-to-merge.sh

**Files:**
- Create: `scripts/scrum/mark-pbi-ready-to-merge.sh`
- Test: `tests/unit/scrum-state/test_mark-pbi-ready-to-merge.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats

setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-rtm.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-rtm.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"impl_ut","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/src.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "first"
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-ready-to-merge: sets phase, head_sha, paths_touched, ready_at" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "ready_to_merge" ]
  run jq -r '.paths_touched | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.paths_touched[0]' .scrum/pbi/pbi-001/state.json
  [ "$output" = "src.txt" ]
  run jq -r '.head_sha' .scrum/pbi/pbi-001/state.json
  EXPECTED="$(git -C .scrum/worktrees/pbi-001 rev-parse HEAD)"
  [ "$output" = "$EXPECTED" ]
  run jq -r '.ready_at' .scrum/pbi/pbi-001/state.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "mark-ready-to-merge: backlog status projects to review" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "review" ]
}

@test "mark-ready-to-merge: refuses if no commits diverge from base" {
  # Reset branch to base so diff is empty.
  WT=.scrum/worktrees/pbi-001
  git -C "$WT" reset --hard HEAD~1
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_mark-pbi-ready-to-merge.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/mark-pbi-ready-to-merge.sh — Developer-side handoff wrapper.
# Computes paths_touched (base..HEAD) and atomically sets phase/head/ready.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/derive.sh
source "$HERE/lib/derive.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: mark-pbi-ready-to-merge.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
WT="$(jq -r '.worktree // ""' "$STATE")"
BASE="$(jq -r '.base_sha // ""' "$STATE")"
[ -d "$WT" ] || fail E_FILE_MISSING "PBI worktree missing: $WT"
[ -n "$BASE" ] || fail E_INVALID_ARG "state.base_sha unset"

HEAD="$(git -C "$WT" rev-parse HEAD)"
mapfile -t PATHS < <(git -C "$WT" diff --name-only "$BASE..HEAD")
if [ "${#PATHS[@]}" -eq 0 ]; then
  fail E_INVALID_ARG "no commits beyond base — refusing to mark ready_to_merge"
fi

# Build paths_touched array literal for jq (use --argjson via env file).
PATHS_JSON="$(printf '%s\n' "${PATHS[@]}" | jq -R . | jq -s .)"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

EXPR=".phase = \"ready_to_merge\""
EXPR="$EXPR | .head_sha = \"$HEAD\""
EXPR="$EXPR | .ready_at = \"$NOW\""
EXPR="$EXPR | .paths_touched = $PATHS_JSON"

atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Project to backlog status (review).
DERIVED="$(derive_backlog_status_from_phase ready_to_merge)"
BACKLOG=".scrum/backlog.json"
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
if [ -f "$BACKLOG" ] && jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$BACKLOG" >/dev/null; then
  atomic_write "$BACKLOG" "(.items[] | select(.id == \"$PBI\")).status = \"$DERIVED\"" "$BACKLOG_SCHEMA"
fi

printf '[mark-pbi-ready-to-merge] %s @ %s (%d paths)\n' "$PBI" "$HEAD" "${#PATHS[@]}"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/mark-pbi-ready-to-merge.sh
bats tests/unit/scrum-state/test_mark-pbi-ready-to-merge.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/mark-pbi-ready-to-merge.sh tests/unit/scrum-state/test_mark-pbi-ready-to-merge.bats
git commit -m "feat(scrum-state): add mark-pbi-ready-to-merge.sh wrapper"
```

---

### Task B5: mark-pbi-merged.sh

**Files:**
- Create: `scripts/scrum/mark-pbi-merged.sh`
- Test: `tests/unit/scrum-state/test_mark-pbi-merged.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-merged.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-merged.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"ready_to_merge","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","head_sha":"abcdef0","branch":"pbi/pbi-001","worktree":".scrum/worktrees/pbi-001","base_sha":"1111111","paths_touched":["a"],"ready_at":"2026-05-04T11:00:00Z"}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"review"}]}
EOF
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-merged: sets phase, merged_sha, merged_at; mirrors to backlog" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -eq 0 ]
  run jq -r '"\(.phase)|\(.merged_sha)"' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merged|abcdef0" ]
  run jq -r '.items[0].merged_sha' .scrum/backlog.json
  [ "$output" = "abcdef0" ]
}

@test "mark-merged: refuses if phase is not ready_to_merge" {
  jq '.phase = "design"' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 abcdef0
  [ "$status" -ne 0 ]
}

@test "mark-merged: rejects malformed sha" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merged.sh" pbi-001 NOT_HEX
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_mark-pbi-merged.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merged.sh — record successful merge into main.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/errors.sh"
source "$HERE/lib/atomic.sh"

[ "$#" -eq 2 ] || fail E_INVALID_ARG "usage: mark-pbi-merged.sh <pbi-id> <merged-sha>"
PBI="$1"; SHA="$2"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac
case "$SHA" in [0-9a-f]*) [ ${#SHA} -ge 7 ] && [ ${#SHA} -le 40 ] || fail E_INVALID_ARG "merged-sha length 7..40 required" ;; *) fail E_INVALID_ARG "merged-sha must be hex" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PREV="$(jq -r '.phase' "$STATE")"
[ "$PREV" = "ready_to_merge" ] || fail E_INVALID_ARG "expected phase=ready_to_merge, got $PREV"

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EXPR=".phase = \"merged\" | .merged_sha = \"$SHA\" | .merged_at = \"$NOW\" | .merge_failure_count = 0"
atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Mirror merged_sha + merged_at to backlog item; status projection already happens via update-pbi-state path elsewhere.
BACKLOG=".scrum/backlog.json"
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
if [ -f "$BACKLOG" ] && jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$BACKLOG" >/dev/null; then
  EXPR_B="(.items[] | select(.id == \"$PBI\")).merged_sha = \"$SHA\" | (.items[] | select(.id == \"$PBI\")).merged_at = \"$NOW\" | (.items[] | select(.id == \"$PBI\")).status = \"review\""
  atomic_write "$BACKLOG" "$EXPR_B" "$BACKLOG_SCHEMA"
fi

printf '[mark-pbi-merged] %s @ %s\n' "$PBI" "$SHA"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/mark-pbi-merged.sh
bats tests/unit/scrum-state/test_mark-pbi-merged.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/mark-pbi-merged.sh tests/unit/scrum-state/test_mark-pbi-merged.bats
git commit -m "feat(scrum-state): add mark-pbi-merged.sh wrapper"
```

---

### Task B6: mark-pbi-merge-failure.sh

**Files:**
- Create: `scripts/scrum/mark-pbi-merge-failure.sh`
- Test: `tests/unit/scrum-state/test_mark-pbi-merge-failure.bats`

Behavior:
- Args: `<pbi-id> <kind> <pre_head_sha> [paths_csv|report_path]`
- `kind ∈ conflict | artifact_missing | regression`
- Sets `phase = merge_<kind>` (mapping conflict→merge_conflict etc.), records `merge_failure` object, increments `merge_failure_count`
- On 3rd consecutive failure: sets `phase = escalated` and `escalation_reason = stagnation` instead of `merge_<kind>`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/mark-fail.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/mark-fail.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"ready_to_merge","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"review"}]}
EOF
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "mark-failure conflict: sets merge_conflict + records paths + increments counter" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 conflict abcdef0 "src/a,src/b"
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merge_conflict" ]
  run jq -r '.merge_failure_count' .scrum/pbi/pbi-001/state.json
  [ "$output" = "1" ]
  run jq -r '.merge_failure.kind' .scrum/pbi/pbi-001/state.json
  [ "$output" = "conflict" ]
  run jq -r '.merge_failure.paths | length' .scrum/pbi/pbi-001/state.json
  [ "$output" = "2" ]
}

@test "mark-failure regression: stores report_path" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 regression abcdef0 ".scrum/pbi/pbi-001/qg.log"
  [ "$status" -eq 0 ]
  run jq -r '.merge_failure.report_path' .scrum/pbi/pbi-001/state.json
  [ "$output" = ".scrum/pbi/pbi-001/qg.log" ]
}

@test "mark-failure: 3rd consecutive failure escalates" {
  # set counter to 2 first
  jq '.merge_failure_count = 2' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-merge-failure.sh" pbi-001 conflict abcdef0 "src/a"
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "escalated" ]
  run jq -r '.escalation_reason' .scrum/pbi/pbi-001/state.json
  [ "$output" = "stagnation" ]
  run jq -r '.items[0].status' .scrum/backlog.json
  [ "$output" = "blocked" ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_mark-pbi-merge-failure.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/mark-pbi-merge-failure.sh — record a merge failure attempt.
# Args: <pbi-id> <kind> <pre_head_sha> <detail>
#   kind=conflict|artifact_missing → detail is comma-separated paths
#   kind=regression                → detail is a single report_path
# Increments merge_failure_count; on count=3 promotes phase to escalated.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/errors.sh"
source "$HERE/lib/atomic.sh"
source "$HERE/lib/derive.sh"

[ "$#" -eq 4 ] || fail E_INVALID_ARG "usage: mark-pbi-merge-failure.sh <pbi-id> <kind> <pre-head-sha> <detail>"
PBI="$1"; KIND="$2"; PRE="$3"; DETAIL="$4"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac
case "$KIND" in conflict|artifact_missing|regression) ;; *) fail E_INVALID_ARG "bad kind: $KIND" ;; esac
case "$PRE" in [0-9a-f]*) [ ${#PRE} -ge 7 ] || fail E_INVALID_ARG "pre-head sha too short" ;; *) fail E_INVALID_ARG "pre-head must be hex" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"

PREV_COUNT="$(jq -r '.merge_failure_count // 0' "$STATE")"
NEW_COUNT=$((PREV_COUNT + 1))

# Build merge_failure object
case "$KIND" in
  conflict|artifact_missing)
    PATHS_JSON="$(printf '%s' "$DETAIL" | tr ',' '\n' | jq -R . | jq -s .)"
    MF="{\"kind\":\"$KIND\",\"pre_head_at_failure\":\"$PRE\",\"paths\":$PATHS_JSON}"
    ;;
  regression)
    MF="{\"kind\":\"regression\",\"pre_head_at_failure\":\"$PRE\",\"report_path\":\"$DETAIL\"}"
    ;;
esac

# Decide phase: escalate at 3rd failure
if [ "$NEW_COUNT" -ge 3 ]; then
  NEW_PHASE="escalated"
  EXPR=".phase = \"escalated\" | .escalation_reason = \"stagnation\" | .merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
else
  case "$KIND" in
    conflict)          NEW_PHASE="merge_conflict" ;;
    artifact_missing)  NEW_PHASE="merge_artifact_missing" ;;
    regression)        NEW_PHASE="merge_regression" ;;
  esac
  EXPR=".phase = \"$NEW_PHASE\" | .merge_failure = $MF | .merge_failure_count = $NEW_COUNT"
fi

atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Project to backlog
DERIVED="$(derive_backlog_status_from_phase "$NEW_PHASE")"
BACKLOG=".scrum/backlog.json"
BACKLOG_SCHEMA="$ROOT/docs/contracts/scrum-state/backlog.schema.json"
if [ -f "$BACKLOG" ] && jq -e --arg id "$PBI" '.items | map(select(.id==$id)) | length > 0' "$BACKLOG" >/dev/null; then
  atomic_write "$BACKLOG" "(.items[] | select(.id == \"$PBI\")).status = \"$DERIVED\"" "$BACKLOG_SCHEMA"
fi

printf '[mark-pbi-merge-failure] %s kind=%s count=%d phase=%s\n' "$PBI" "$KIND" "$NEW_COUNT" "$NEW_PHASE"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/mark-pbi-merge-failure.sh
bats tests/unit/scrum-state/test_mark-pbi-merge-failure.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/mark-pbi-merge-failure.sh tests/unit/scrum-state/test_mark-pbi-merge-failure.bats
git commit -m "feat(scrum-state): add mark-pbi-merge-failure.sh with 3-strike escalation"
```

---

### Task B7: cleanup-pbi-worktree.sh

**Files:**
- Create: `scripts/scrum/cleanup-pbi-worktree.sh`
- Test: `tests/unit/scrum-state/test_cleanup-pbi-worktree.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/cleanup.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/cleanup.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"merged","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z"}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "cleanup: removes worktree and branch" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
  [ ! -d .scrum/worktrees/pbi-001 ]
  run git branch --list pbi/pbi-001
  [ -z "$output" ]
}

@test "cleanup: idempotent — second call clean" {
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -eq 0 ]
}

@test "cleanup: refuses if phase not in {merged, escalated}" {
  jq '.phase = "ready_to_merge"' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/cleanup-pbi-worktree.sh" pbi-001
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_cleanup-pbi-worktree.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/cleanup-pbi-worktree.sh — remove worktree + branch after merge or escalation.
# Idempotent. Refuses for non-terminal phases to prevent accidental work loss.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: cleanup-pbi-worktree.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PHASE="$(jq -r '.phase' "$STATE")"
case "$PHASE" in
  merged|escalated) ;;
  *) fail E_INVALID_ARG "refuse to cleanup pbi $PBI in phase=$PHASE (need merged or escalated)" ;;
esac

WT=".scrum/worktrees/$PBI"
BRANCH="pbi/$PBI"

if [ -d "$WT" ]; then
  git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
fi
if git show-ref --quiet --heads "$BRANCH"; then
  git branch -D "$BRANCH" >/dev/null
fi
# Prune git worktree metadata
git worktree prune >/dev/null 2>&1 || true

printf '[cleanup-pbi-worktree] removed %s and branch %s\n' "$WT" "$BRANCH"
```

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/cleanup-pbi-worktree.sh
bats tests/unit/scrum-state/test_cleanup-pbi-worktree.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/cleanup-pbi-worktree.sh tests/unit/scrum-state/test_cleanup-pbi-worktree.bats
git commit -m "feat(scrum-state): add cleanup-pbi-worktree.sh wrapper"
```

---

### Task B8: merge-pbi.sh (orchestrator)

**Files:**
- Create: `scripts/scrum/merge-pbi.sh`
- Test: `tests/unit/scrum-state/test_merge-pbi.bats`

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats
setup() {
  export SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/merge-pbi.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/merge-pbi.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum/pbi/pbi-001 docs/contracts/scrum-state
  for s in sprint pbi-state backlog; do cp "$PROJECT_ROOT/docs/contracts/scrum-state/${s}.schema.json" docs/contracts/scrum-state/; done
  git init -q -b main
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m "init"
  SHA="$(git rev-parse HEAD)"
  cat > .scrum/sprint.json <<EOF
{"id":"sprint-001","status":"active","started_at":"2026-05-04T10:00:00Z","base_sha":"$SHA","base_sha_captured_at":"2026-05-04T10:00:00Z"}
EOF
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{"pbi_id":"pbi-001","phase":"impl_ut","started_at":"2026-05-04T10:00:00Z","updated_at":"2026-05-04T10:00:00Z","merge_failure_count":0}
EOF
  cat > .scrum/backlog.json <<'EOF'
{"items":[{"id":"pbi-001","title":"x","status":"in_progress"}]}
EOF
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/create-pbi-worktree.sh" pbi-001
  echo "hello" > .scrum/worktrees/pbi-001/file.txt
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/commit-pbi.sh" pbi-001 "feat: file"
  env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli "$PROJECT_ROOT/scripts/scrum/mark-pbi-ready-to-merge.sh" pbi-001
  # Disable quality-gate by stubbing
  export SCRUM_SKIP_QUALITY_GATE=1
}
teardown() { [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"; }

@test "merge-pbi: success path — merges, verifies, cleans up" {
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli SCRUM_SKIP_QUALITY_GATE=1 "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -eq 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merged" ]
  run git log --oneline main
  echo "$output" | grep -q "merge: pbi-001"
  [ ! -d .scrum/worktrees/pbi-001 ]
}

@test "merge-pbi: artifact_missing — paths_touched contains a file deleted in branch" {
  WT=.scrum/worktrees/pbi-001
  # Recreate worktree+branch: simulate a paths_touched entry that doesn't end up on HEAD
  jq '.paths_touched = ["nonexistent.txt"]' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli SCRUM_SKIP_QUALITY_GATE=1 "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
  run jq -r '.phase' .scrum/pbi/pbi-001/state.json
  [ "$output" = "merge_artifact_missing" ]
  # main HEAD should be back to original
  run git log --oneline main
  ! echo "$output" | grep -q "merge: pbi-001"
}

@test "merge-pbi: refuses non-ready_to_merge phase" {
  jq '.phase = "design"' .scrum/pbi/pbi-001/state.json > /tmp/x && mv /tmp/x .scrum/pbi/pbi-001/state.json
  run env SCRUM_VALIDATOR_OVERRIDE=jsonschema-cli SCRUM_SKIP_QUALITY_GATE=1 "$PROJECT_ROOT/scripts/scrum/merge-pbi.sh" pbi-001
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/scrum-state/test_merge-pbi.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# scripts/scrum/merge-pbi.sh — SM-side merge orchestrator.
# Phases: pre-check → no-ff merge → artifact verify → quality-gate → record → cleanup.
# Failure modes call mark-pbi-merge-failure.sh and roll back main.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/errors.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: merge-pbi.sh <pbi-id>"
PBI="$1"
case "$PBI" in pbi-[0-9]*) ;; *) fail E_INVALID_ARG "bad pbi-id: $PBI" ;; esac

STATE=".scrum/pbi/$PBI/state.json"
[ -f "$STATE" ] || fail E_FILE_MISSING "$STATE"
PHASE="$(jq -r '.phase' "$STATE")"
[ "$PHASE" = "ready_to_merge" ] || fail E_INVALID_ARG "expected phase=ready_to_merge, got $PHASE"
BRANCH="$(jq -r '.branch' "$STATE")"
mapfile -t PATHS < <(jq -r '.paths_touched[]' "$STATE")

# Lock main worktree against parallel merges
mkdir -p .scrum/.locks
LOCK=.scrum/.locks/merge.lock
exec 9>"$LOCK"
flock -w 30 9 || fail E_LOCK_TIMEOUT "another merge is in progress"

# Working tree must be clean
if [ -n "$(git status --porcelain)" ]; then
  fail E_INVALID_ARG "main worktree has uncommitted changes — refuse to merge"
fi

PRE_HEAD="$(git rev-parse HEAD)"

# Make sure we are on main
git checkout main >/dev/null 2>&1 || fail E_INVALID_ARG "could not checkout main"

# Attempt merge
if ! git merge --no-ff "$BRANCH" -m "merge: $PBI" >/dev/null 2>&1; then
  # Conflict — collect conflicting paths, abort, record
  CONFLICT_PATHS="$(git diff --name-only --diff-filter=U | tr '\n' ',' | sed 's/,$//')"
  git merge --abort 2>/dev/null || true
  "$HERE/mark-pbi-merge-failure.sh" "$PBI" conflict "$PRE_HEAD" "$CONFLICT_PATHS"
  fail E_INVALID_ARG "merge conflict: $CONFLICT_PATHS"
fi

# Verify artifacts present at HEAD
MISSING=()
for p in "${PATHS[@]}"; do
  if ! git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    MISSING+=("$p")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  CSV="$(IFS=,; echo "${MISSING[*]}")"
  git reset --hard "$PRE_HEAD" >/dev/null
  "$HERE/mark-pbi-merge-failure.sh" "$PBI" artifact_missing "$PRE_HEAD" "$CSV"
  fail E_INVALID_ARG "artifact_missing: $CSV"
fi

# Run quality-gate (skippable for tests)
if [ "${SCRUM_SKIP_QUALITY_GATE:-0}" != "1" ]; then
  REPORT=".scrum/pbi/$PBI/quality-gate-out.log"
  if ! "$ROOT/hooks/quality-gate.sh" >"$REPORT" 2>&1; then
    git reset --hard "$PRE_HEAD" >/dev/null
    "$HERE/mark-pbi-merge-failure.sh" "$PBI" regression "$PRE_HEAD" "$REPORT"
    fail E_INVALID_ARG "merge_regression — see $REPORT"
  fi
fi

MERGED_SHA="$(git rev-parse HEAD)"
"$HERE/mark-pbi-merged.sh" "$PBI" "$MERGED_SHA"

# Cleanup the worktree + branch
"$HERE/cleanup-pbi-worktree.sh" "$PBI"

printf '[merge-pbi] %s merged at %s\n' "$PBI" "$MERGED_SHA"
```

Note on `hooks/quality-gate.sh` invocation: the hook reads cwd-relative state and exits non-zero on failure. If your project uses a non-default trigger (e.g. specific path), wrap it through a shim deployed by `setup-user.sh` (handled in F1).

- [ ] **Step 4: Test passes**

```bash
chmod +x scripts/scrum/merge-pbi.sh
bats tests/unit/scrum-state/test_merge-pbi.bats
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/scrum/merge-pbi.sh tests/unit/scrum-state/test_merge-pbi.bats
git commit -m "feat(scrum-state): add merge-pbi.sh orchestrator with artifact verification"
```

---

## Phase C: Hook

### Task C1: pre-tool-use-no-branch-ops.sh

**Files:**
- Create: `hooks/pre-tool-use-no-branch-ops.sh`
- Test: `tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats`

Hook input: Claude Code passes the tool invocation as JSON on stdin (per existing hooks/pre-tool-use-* convention). Block when the Bash command attempts a branch-creating or branch-changing op AND it is not invoked through `.scrum/scripts/`.

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bats
setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  HOOK="$PROJECT_ROOT/hooks/pre-tool-use-no-branch-ops.sh"
}

@test "blocks: git checkout -b" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git checkout -b foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git switch -c" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch -c foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git branch newname" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git branch newname\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: direct git merge" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git merge other\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git push" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git rebase" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "allows: git status" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git log --oneline" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log --oneline\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: branch op via .scrum/scripts/ wrapper" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\".scrum/scripts/merge-pbi.sh pbi-001\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks: non-Bash tools pass through" {
  run bash -c "echo '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}
```

Save under `tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats`. Create the directory if needed:
```bash
mkdir -p tests/unit/hooks
```

- [ ] **Step 2: Run, expect fail**

```bash
bats tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats
```

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# hooks/pre-tool-use-no-branch-ops.sh — block free-form git branch / merge / push / rebase
# from the Bash tool. Allows .scrum/scripts/* wrappers (which encapsulate the workflow).
# Receives Claude Code tool invocation JSON on stdin.
set -euo pipefail

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[ "$TOOL" = "Bash" ] || exit 0  # non-Bash tools: not our concern

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[ -n "$CMD" ] || exit 0

# Allow if the command (after leading whitespace) starts with a wrapper invocation.
case "${CMD#"${CMD%%[![:space:]]*}"}" in
  .scrum/scripts/*|*'/.scrum/scripts/'*) exit 0 ;;
esac

# Patterns: any of these in the command is a hard block.
# We match on word-boundaries to avoid false positives ("git status" should pass).
block() {
  printf '[no-branch-ops] BLOCKED: %s. Use .scrum/scripts/* wrappers instead.\n' "$1" >&2
  exit 2
}

if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+checkout[[:space:]]+-b\b'; then
  block "git checkout -b"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+switch[[:space:]]+-c\b'; then
  block "git switch -c"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+branch[[:space:]]+[A-Za-z0-9._/-]+($|[[:space:];|&])'; then
  # `git branch <name>` (creates). Listing forms (`git branch`, `git branch -a`, `git branch --list`) pass.
  block "git branch <new-name>"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+merge\b'; then
  block "git merge"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+push\b'; then
  block "git push"
fi
if echo "$CMD" | grep -Eq '(^|[[:space:];|&])git[[:space:]]+rebase\b'; then
  block "git rebase"
fi

exit 0
```

- [ ] **Step 4: Tests pass**

```bash
chmod +x hooks/pre-tool-use-no-branch-ops.sh
bats tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats
```
Expected: 10 PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/pre-tool-use-no-branch-ops.sh tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats
git commit -m "feat(hooks): add pre-tool-use-no-branch-ops to block free-form git ops"
```

---

## Phase D: New skill

### Task D1: skills/pbi-merge/SKILL.md

**Files:**
- Create: `skills/pbi-merge/SKILL.md`

- [ ] **Step 1: Create skill file**

```markdown
---
name: pbi-merge
description: >
  SM-side merge orchestration for a single PBI. Triggered when the
  Developer notifies `[<pbi-id>] PBI_READY_TO_MERGE`. Drives
  `.scrum/scripts/merge-pbi.sh` and handles the failure / retry
  cycle through SendMessage to the assigned Developer.
disable-model-invocation: false
---

## Inputs

- `<pbi-id>` (from the notification line)
- `.scrum/pbi/<pbi-id>/state.json` (must be `phase = ready_to_merge`)
- `.scrum/sprint.json.developers[]` (to find the Developer to message)

## Outputs

- One of:
  - `.scrum/pbi/<pbi-id>/state.json.phase = "merged"` (success)
  - `.scrum/pbi/<pbi-id>/state.json.phase ∈ {merge_conflict, merge_artifact_missing, merge_regression}` (recoverable)
  - `.scrum/pbi/<pbi-id>/state.json.phase = "escalated"` (after 3rd consecutive failure)
- `backlog.json items[].merged_sha` mirrored on success
- Worktree `.scrum/worktrees/<pbi-id>` removed on success
- Sprint-level state untouched

## Preconditions

- SM has just received `[<pbi-id>] PBI_READY_TO_MERGE` from a Developer
- `.scrum/pbi/<pbi-id>/state.json.phase == "ready_to_merge"`
- Main worktree is clean (`git status --porcelain` empty)

## Steps

1. **Acquire lock by serial processing.** If another `pbi-merge` skill
   invocation is in flight (multiple ready-to-merge notifications
   arrived close together), do not run them in parallel. Process them
   in receive order. The wrapper itself uses `flock` as a backstop.

2. **Run the wrapper:**
   ```
   bash .scrum/scripts/merge-pbi.sh <pbi-id>
   ```

3. **Branch on exit code:**
   - exit 0 → re-read `state.json`, find `merged_sha`. SendMessage to
     Developer (`sprint.json.developers[].current_pbi == <pbi-id>`):
     `[<pbi-id>] MERGED at <merged_sha>. Stand by for next assignment.`
   - non-zero → re-read `state.json.phase`:
     - `merge_conflict` → SendMessage:
       `[<pbi-id>] MERGE_CONFLICT paths=[<state.merge_failure.paths>]. Rebase pbi/<pbi-id> onto main HEAD <git rev-parse main>, fix, re-notify PBI_READY_TO_MERGE.`
     - `merge_artifact_missing` → SendMessage:
       `[<pbi-id>] ARTIFACT_MISSING paths=[<state.merge_failure.paths>]. Re-add files to pbi/<pbi-id> branch (likely lost during a rebase or .gitignore mishap), re-notify PBI_READY_TO_MERGE.`
     - `merge_regression` → SendMessage:
       `[<pbi-id>] MERGE_REGRESSION. Failed checks: see <state.merge_failure.report_path>. Fix on pbi/<pbi-id>, re-notify.`
     - `escalated` → invoke `pbi-escalation-handler` skill with
       `<pbi-id>` (3-strike rule has tripped; further Developer
       iteration is unproductive).

4. **No further coordination work** until the merge attempt finishes
   and the Developer (if applicable) has been messaged. Receive
   priority: equal to `pbi-escalation-handler`.

## Exit Criteria

- `state.phase ∈ {merged, merge_*, escalated}` and the corresponding
  SendMessage / handler invocation has been issued.

## Strict Rules

- Never invoke `git merge`, `git checkout`, `git branch`, `git rebase`,
  or `git push` directly. The wrapper handles all git operations.
- Never edit `.scrum/pbi/<id>/state.json` manually; the wrapper writes
  through `mark-pbi-*` helpers.
- Never run two `pbi-merge` invocations in parallel — even though the
  wrapper has a `flock`, the SendMessage ordering depends on serial
  processing.
```

- [ ] **Step 2: Verify the skill file is well-formed**

```bash
head -10 skills/pbi-merge/SKILL.md
ls skills/pbi-merge/
```
Expected: SKILL.md present, frontmatter visible.

- [ ] **Step 3: Commit**

```bash
git add skills/pbi-merge/SKILL.md
git commit -m "feat(skill): add pbi-merge skill for SM-side merge orchestration"
```

---

## Phase E: Agent + skill text updates

### Task E1: agents/developer.md

**Files:**
- Modify: `agents/developer.md`

- [ ] **Step 1: Edit Strict Rules**

In the `## Strict Rules` section, append:

```markdown
- **Worktree boundary.** All file operations must be inside the PBI worktree at `.scrum/worktrees/<pbi-id>`. Never edit files in the main worktree.
- **No branch ops.** Never run `git checkout -b`, `git switch -c`, `git branch <name>`, `git push`, `git merge`, or `git rebase` directly. Use `.scrum/scripts/*` wrappers (`commit-pbi.sh` for commits, `mark-pbi-ready-to-merge.sh` for handoff). The `pre-tool-use-no-branch-ops.sh` hook will block raw git branch / push / merge / rebase commands.
- **Commits go through `commit-pbi.sh`** which verifies the worktree is on `pbi/<pbi-id>`. A wrong-branch state means the worktree was tampered with — stop and report.
- **PBI completion = `mark-pbi-ready-to-merge.sh`** then notify SM `[<pbi-id>] PBI_READY_TO_MERGE branch=<branch> sha=<sha>`. Stop after notifying — SM owns the merge.
```

- [ ] **Step 2: Edit State Files section**

Replace the bullet that ends with `Created and managed by the pbi-pipeline skill.` with:

```markdown
- `.scrum/pbi/<pbi-id>/` — PBI working area (state.json, design/,
  impl/, ut/, metrics/, feedback/, pipeline.log). Created and managed
  by the pbi-pipeline skill. New fields populated by the worktree /
  merge wrappers: `branch`, `worktree`, `base_sha`, `head_sha`,
  `paths_touched`, `ready_at`, `merged_sha`, `merged_at`,
  `merge_failure`, `merge_failure_count`.
- `.scrum/worktrees/<pbi-id>/` — git worktree for the PBI's own
  branch (`pbi/<pbi-id>`). Read/write within. Has a `.scrum`
  symlink back to the main repo's SSOT. Created by SM via
  `create-pbi-worktree.sh`; removed after merge.
```

- [ ] **Step 3: Commit**

```bash
git add agents/developer.md
git commit -m "docs(developer): require PBI worktree + wrapper-only git ops"
```

---

### Task E2: agents/scrum-master.md

**Files:**
- Modify: `agents/scrum-master.md`

- [ ] **Step 1: Add `pbi-merge` to skills frontmatter**

In the `skills:` list at the top, add `- pbi-merge` after `- pbi-escalation-handler`.

- [ ] **Step 2: Update Allowed list**

Replace the `**Allowed:**` block with:

```markdown
**Allowed:**
- Manage tasks, assign work to Developers (Agent Teams)
- Read/update `.scrum/` state JSON
- Update `docs/design/catalog-config.json` (enable/disable spec IDs)
- Read `docs/design/catalog.md` (read-only)
- Run `.scrum/scripts/*` wrappers (state writes + git operations: worktree creation, merge, cleanup)
- Present Sprint Reviews and Retrospectives
```

- [ ] **Step 3: Add a workflow section**

After the `## Phase Transition Rule` section, add:

```markdown
## Per-PBI Merge Trigger

When a Developer reports `[<pbi-id>] PBI_READY_TO_MERGE branch=<n> sha=<x>`,
immediately invoke the `pbi-merge` skill with that PBI id. Priority
equals `pbi-escalation-handler` — do not perform other coordination
work until the skill completes (success OR failure handoff to
Developer / escalation).

**Concurrency:** Multiple `PBI_READY_TO_MERGE` notifications may
arrive close together when several PBIs finish in parallel. Process
them strictly in receive order. Do not invoke `pbi-merge` twice in
parallel — the underlying `merge-pbi.sh` wrapper has a `flock`
backstop, but SendMessage ordering must be deterministic.
```

- [ ] **Step 4: Commit**

```bash
git add agents/scrum-master.md
git commit -m "docs(scrum-master): allow scrum-state wrappers + add merge trigger"
```

---

### Task E3: skills/spawn-teammates/SKILL.md

**Files:**
- Modify: `skills/spawn-teammates/SKILL.md`

- [ ] **Step 1: Insert Step 0 (freeze base)**

Before the existing `## Steps` numbered list `1.`, insert:

```markdown
0. **Freeze Sprint base.** Run
   `bash .scrum/scripts/freeze-sprint-base.sh`. This captures
   `sprint.json.base_sha = $(git rev-parse HEAD)` exactly once per
   Sprint. PBI worktrees fork from this commit.
```

- [ ] **Step 2: Insert Step 5.5 (create worktrees)**

After the existing Step 5 `Each Developer:` block, before `Reconcile backlog.json`, insert:

```markdown
5.5. **Create PBI worktrees.** For each PBI assigned in this Sprint
     run:
     ```
     bash .scrum/scripts/create-pbi-worktree.sh <pbi-id>
     ```
     This creates `.scrum/worktrees/<pbi-id>` checked out at
     `pbi/<pbi-id>` forked from `sprint.base_sha`, sets up the
     `.scrum` symlink, and writes `branch`, `worktree`, `base_sha`
     into `.scrum/pbi/<pbi-id>/state.json`.
```

- [ ] **Step 3: Update Step 8 task prompt**

Replace the existing Step 8 task prompt block with:

```markdown
8. Spawn Agent Teams teammates (agents/developer.md). Name = exact ID from 5a. Task:
   ```
   Your working directory: <ABSOLUTE_PATH>/.scrum/worktrees/<pbi-id>
   First action: cd "<ABSOLUTE_PATH>/.scrum/worktrees/<pbi-id>"
   All file operations and commits must stay inside this directory.
   Use `.scrum/scripts/commit-pbi.sh` for commits — never raw `git commit`.

   Execute these skills in order for your assigned PBIs:
   1. Invoke the `design` skill
   2. Invoke the `implementation` skill
   3. Invoke the `cross-review` skill
   Do NOT skip or reorder these steps.

   When the pbi-pipeline reaches phase=complete, run
   `.scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>` and notify
   SM: `[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<pbi-id> sha=<head>`.
   Then stop and wait.
   ```
```

(Substitute `<ABSOLUTE_PATH>` with the absolute path to the project root, and `<pbi-id>` with each Developer's assigned PBI id.)

- [ ] **Step 4: Commit**

```bash
git add skills/spawn-teammates/SKILL.md
git commit -m "docs(spawn-teammates): freeze base, create worktrees, brief Developers on wrappers"
```

---

### Task E4: skills/pbi-pipeline/{SKILL.md, references/state-management.md}

**Files:**
- Modify: `skills/pbi-pipeline/SKILL.md`
- Modify: `skills/pbi-pipeline/references/state-management.md`

- [ ] **Step 1: Update SKILL.md Outputs**

Replace the line:
```
- Source code + test code committed to project (normal paths)
```
with:
```
- Source code + test code committed to the PBI branch in the PBI
  worktree via `.scrum/scripts/commit-pbi.sh`. Never commit
  directly with raw `git commit`.
```

- [ ] **Step 2: Update SKILL.md Phases**

Replace the line:
```
[Completion] update backlog.json + notify SM
```
with:
```
[Completion]
   - run .scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>
     (sets phase=ready_to_merge, head_sha, paths_touched, ready_at;
     projects backlog status to review)
   - notify SM: "[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<id> sha=<head>"
   - stop and wait for SM SendMessage (MERGED / MERGE_CONFLICT /
     ARTIFACT_MISSING / MERGE_REGRESSION)
```

- [ ] **Step 3: Update Exit Criteria**

Replace the existing Exit Criteria block with:

```markdown
## Exit Criteria

- state.json: `phase = ready_to_merge` OR `phase = escalated`
- backlog.json items[].status reflects the projected value (`review`
  for both ready_to_merge and merged; `blocked` for escalated). The
  pipeline does not write it directly.
- SM notified
```

- [ ] **Step 4: Update references/state-management.md**

In the schema section, append the new fields:

```markdown
## New fields (worktree / merge governance)

- `branch`, `worktree`, `base_sha` — written by `create-pbi-worktree.sh`
  at Sprint start
- `head_sha` — updated each round by `commit-pbi.sh`
- `paths_touched`, `ready_at` — written by `mark-pbi-ready-to-merge.sh`
- `merged_sha`, `merged_at` — written by `mark-pbi-merged.sh`
- `merge_failure`, `merge_failure_count` — written by
  `mark-pbi-merge-failure.sh`

## Phase → status projection (extended)

| state.phase | items[].status |
|---|---|
| design / impl_ut | in_progress |
| complete | review |
| ready_to_merge | review |
| merged | review |
| merge_conflict / merge_artifact_missing / merge_regression | review |
| escalated | blocked |
| review_complete | done |
```

- [ ] **Step 5: Commit**

```bash
git add skills/pbi-pipeline/SKILL.md skills/pbi-pipeline/references/state-management.md
git commit -m "docs(pbi-pipeline): handoff via mark-pbi-ready-to-merge + new fields"
```

---

### Task E5: skills/cross-review/SKILL.md

**Files:**
- Modify: `skills/cross-review/SKILL.md`

- [ ] **Step 1: Update Preconditions**

Replace the precondition that mentions `pbi/<id>/state.json.phase = complete` with:

```markdown
- All Sprint PBIs at `pbi/<id>/state.json.phase ∈ {merged, escalated}`.
  PBIs in `ready_to_merge` or `merge_*` failure states must be
  driven to one of those terminal states (via `pbi-merge` or
  `pbi-escalation-handler`) before this skill is invoked.
- Review target: the merged main HEAD (only the merged PBIs).
```

- [ ] **Step 2: Commit**

```bash
git add skills/cross-review/SKILL.md
git commit -m "docs(cross-review): require merged|escalated terminal state before review"
```

---

### Task E6: skills/sprint-planning/SKILL.md

**Files:**
- Modify: `skills/sprint-planning/SKILL.md`

- [ ] **Step 1: Add a brief note**

Locate the section discussing path or catalog separation. Append:

```markdown
> **Note (worktree governance).** Per-PBI worktrees give physical
> isolation, so two PBIs touching the same source file no longer
> corrupt each other at write time. Conflicts surface during
> `pbi-merge` and the assigned Developer rebases. Pre-separation is
> still required for catalog files (see `catalog-contention.md`).
```

- [ ] **Step 2: Commit**

```bash
git add skills/sprint-planning/SKILL.md
git commit -m "docs(sprint-planning): note that worktree isolation handles source conflicts"
```

---

## Phase F: Setup + cross-cutting docs

### Task F1: scripts/setup-user.sh

**Files:**
- Modify: `scripts/setup-user.sh`

- [ ] **Step 1: Read current setup script**

```bash
grep -n -E "scripts/scrum|hooks/" scripts/setup-user.sh
```

- [ ] **Step 2: Add new wrappers to deploy list**

Locate the array / loop that copies `scripts/scrum/*.sh` into the
target's `.scrum/scripts/`. Add the new wrappers:

```
scripts/scrum/freeze-sprint-base.sh
scripts/scrum/create-pbi-worktree.sh
scripts/scrum/commit-pbi.sh
scripts/scrum/mark-pbi-ready-to-merge.sh
scripts/scrum/mark-pbi-merged.sh
scripts/scrum/mark-pbi-merge-failure.sh
scripts/scrum/cleanup-pbi-worktree.sh
scripts/scrum/merge-pbi.sh
```

If the existing script uses a glob (`scripts/scrum/*.sh`), no edit
is needed; verify by re-running it against a test target.

- [ ] **Step 3: Register the new hook**

Locate the section that copies `hooks/*.sh` to the target and
registers them in `settings.json` under `hooks.PreToolUse`. Add:

- File copy: `hooks/pre-tool-use-no-branch-ops.sh`
- Registration: append to the `PreToolUse` list a matcher that
  triggers on `Bash` tool. Follow the same shape as the existing
  `pre-tool-use-scrum-state-guard.sh` registration.

- [ ] **Step 4: Smoke test**

```bash
bash scripts/setup-user.sh /tmp/scrum-deploy-test
ls /tmp/scrum-deploy-test/.scrum/scripts/ | grep -E '^(freeze-sprint-base|create-pbi-worktree|commit-pbi|mark-pbi|merge-pbi|cleanup-pbi)'
ls /tmp/scrum-deploy-test/hooks/ 2>/dev/null | grep no-branch-ops
```
Expected: all 8 new wrappers present, hook present.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-user.sh
git commit -m "build(setup): deploy worktree+merge wrappers and no-branch-ops hook"
```

---

### Task F2: docs/MIGRATION-scrum-state-tools.md

**Files:**
- Modify: `docs/MIGRATION-scrum-state-tools.md`

- [ ] **Step 1: Append wrapper map entries**

Add a new section:

```markdown
## Worktree / merge governance wrappers (2026-05-04)

| Wrapper | Writes |
|---|---|
| `freeze-sprint-base.sh` | `sprint.base_sha`, `sprint.base_sha_captured_at` (once per Sprint) |
| `create-pbi-worktree.sh` | `pbi/<id>/state.json` `branch`, `worktree`, `base_sha`; creates git worktree + `.scrum` symlink |
| `commit-pbi.sh` | git commit on `pbi/<id>` branch + `pbi/<id>/state.json.head_sha` |
| `mark-pbi-ready-to-merge.sh` | `pbi/<id>/state.json` `phase=ready_to_merge`, `head_sha`, `paths_touched`, `ready_at`; backlog item `status=review` |
| `mark-pbi-merged.sh` | `pbi/<id>/state.json` `phase=merged`, `merged_sha`, `merged_at`, `merge_failure_count=0`; backlog item `merged_sha`, `merged_at` |
| `mark-pbi-merge-failure.sh` | `pbi/<id>/state.json` `phase ∈ merge_*`, `merge_failure`, `merge_failure_count++`; on 3rd consecutive failure: `phase=escalated`, `escalation_reason=stagnation`, backlog `status=blocked` |
| `cleanup-pbi-worktree.sh` | removes git worktree + `pbi/<id>` branch (post-merge) |
| `merge-pbi.sh` | orchestrator (calls mark-pbi-merged or mark-pbi-merge-failure + cleanup) |
```

- [ ] **Step 2: Commit**

```bash
git add docs/MIGRATION-scrum-state-tools.md
git commit -m "docs(migration): document worktree/merge governance wrapper map"
```

---

### Task F3: CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add Git Workflow section**

After the existing `## State management` section, add:

```markdown
## Git workflow

PBI development uses one git worktree per PBI. The Scrum Master
captures `sprint.base_sha = git rev-parse HEAD` once at Sprint
start, then creates `.scrum/worktrees/<pbi-id>/` checked out at
branch `pbi/<pbi-id>` forked from that base. Each worktree has a
`.scrum -> ../../../.scrum` symlink so the SSOT is shared with the
main repo.

Developers commit only via `.scrum/scripts/commit-pbi.sh` (which
refuses if the checked-out branch is not `pbi/<id>`). On PBI
completion they run `.scrum/scripts/mark-pbi-ready-to-merge.sh`
and notify SM `[<pbi-id>] PBI_READY_TO_MERGE`.

SM merges per-PBI immediately by running the `pbi-merge` skill
which calls `.scrum/scripts/merge-pbi.sh`:
1. `--no-ff` merge into main
2. verify every `paths_touched` file is on HEAD
3. run the existing `hooks/quality-gate.sh`
4. mark `phase=merged`, mirror `merged_sha` to backlog, remove
   worktree + branch

Three failure paths roll back main and instruct the Developer to
fix on `pbi/<id>` and re-notify. Three consecutive failures of any
kind escalate via `pbi-escalation-handler`.

The hook `pre-tool-use-no-branch-ops.sh` blocks raw
`git checkout -b`, `switch -c`, `branch <new>`, `merge`, `push`,
`rebase` from the Bash tool unless invoked through
`.scrum/scripts/*`.
```

- [ ] **Step 2: Update State management section**

Append to the existing `## State management` section a sentence
listing the new fields:

```markdown
The PBI state schema gained worktree / merge fields (`branch`,
`worktree`, `base_sha`, `head_sha`, `paths_touched`, `ready_at`,
`merged_sha`, `merged_at`, `merge_failure`, `merge_failure_count`)
and new phase enum values (`ready_to_merge`, `merged`,
`merge_conflict`, `merge_artifact_missing`, `merge_regression`).
The sprint schema gained `base_sha` and `base_sha_captured_at`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document git workflow and merge governance"
```

---

## Final verification

- [ ] **Run full test suite**

```bash
bats tests/unit/ tests/lint/
shellcheck scripts/scrum/*.sh hooks/*.sh
```
Expected: all PASS, shellcheck clean.

- [ ] **Smoke-deploy and inspect**

```bash
rm -rf /tmp/scrum-deploy-test && bash scripts/setup-user.sh /tmp/scrum-deploy-test
ls /tmp/scrum-deploy-test/.scrum/scripts/
cat /tmp/scrum-deploy-test/.claude/settings.json | jq '.hooks.PreToolUse'
```
Expected: 8 new wrappers in `.scrum/scripts/`; hook entry includes `pre-tool-use-no-branch-ops.sh`.
