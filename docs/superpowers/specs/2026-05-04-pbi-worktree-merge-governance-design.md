# PBI Worktree + Merge Governance Design

- Date: 2026-05-04
- Author: scrum team contributor (assisted)
- Status: proposed
- Supersedes: implicit (none) git workflow in `agents/developer.md` /
  `skills/pbi-pipeline/SKILL.md`

## 1. Problem

The current framework specifies **no git workflow**. `agents/`,
`skills/`, and `hooks/` contain no instructions about branches,
worktrees, commits, merges, pushes, or PRs. Only
`hooks/quality-gate.sh:121` references a base branch (via
`git merge-base`) for diff scoping; no other component touches git
state.

In practice, Developer agents improvise: each Developer creates its
own branch and the merge step is left undefined. Merges happen
ad-hoc at Sprint end (effectively pattern (C) in the brainstorm
notes), and have produced **silent loss of completed PBI
artifacts** — files that were committed on a Developer branch but
did not arrive on `main` after Sprint-end merging. Subsequent
Sprints proceed with the loss undetected until much later.

## 2. Goals

1. Define a single, mandatory git workflow for the framework
2. Make artifact loss **impossible to miss** by adding a verification
   gate at every merge
3. Preserve the parallel Sprint model (`min(refined PBIs, 6)` Developers)
4. Localize the merge responsibility to the Scrum Master, with
   automation handling the mechanics
5. Allow Developers to recover from merge failures without human
   intervention in the common case

## 3. Non-Goals

- Remote push / pull-request workflow with GitHub/GitLab. The merge
  is local-only; integration with remote review tools is out of scope
  for this iteration
- Sprint Planning pre-separation of source paths. PBI worktrees give
  physical isolation; cross-PBI conflicts surface at merge time
  (rebase loop) rather than as runtime corruption
- Migration of in-flight Sprints. The new workflow applies from the
  next Sprint onward

## 4. High-Level Shape

```
Repository root (main worktree)
├── .scrum/                              # SSOT (gitignored)
├── .scrum/worktrees/                    # PBI working trees (gitignored)
│   ├── pbi-001/                         # checked out: pbi/pbi-001
│   │   └── .scrum -> ../../../.scrum    # symlink to SSOT
│   ├── pbi-002/                         # checked out: pbi/pbi-002
│   └── pbi-003/                         # checked out: pbi/pbi-003
└── (Developers never touch the main worktree)
```

- **1 PBI = 1 worktree = 1 branch.** Branch name is `pbi/<pbi-id>`,
  fixed.
- Branches are forked from the **frozen Sprint base** (`sprint.base_sha`),
  captured at Sprint start.
- The `.scrum/` symlink in each worktree resolves the existing
  `$PWD/.scrum/...` access pattern (used by all hooks and wrappers)
  back to the single SSOT in the main repo.
- Worktree path and branch name use the **PBI id** (not Developer id)
  so that Liveness Protocol re-spawns can resume by checking
  worktree existence alone.

## 5. PBI Lifecycle

### 5.1 Creation (Sprint start)

Performed by SM during Sprint Planning, via wrappers, after PBI
assignments are decided in `spawn-teammates`:

1. `.scrum/scripts/freeze-sprint-base.sh` records
   `sprint.json.base_sha = $(git rev-parse HEAD)` and
   `base_sha_captured_at`
2. For each assigned PBI:
   `.scrum/scripts/create-pbi-worktree.sh <pbi-id>` performs
   ```
   git worktree add -b pbi/<pbi-id> .scrum/worktrees/<pbi-id> <sprint.base_sha>
   ln -s ../../../.scrum .scrum/worktrees/<pbi-id>/.scrum
   ```
   and writes the corresponding fields to
   `.scrum/pbi/<pbi-id>/state.json` (`branch`, `worktree`, `base_sha`)
3. `spawn-teammates` then spawns the Developer with a task prompt
   that includes the **absolute** worktree path and an explicit
   `cd` instruction (sub-agents inherit cwd)

### 5.2 Development

- All Developer / sub-agent file ops happen inside the PBI worktree
- All commits go through `.scrum/scripts/commit-pbi.sh <pbi-id> <message>`,
  which:
  - resolves the worktree path from `state.json.worktree`
  - verifies the worktree is checked out at `pbi/<pbi-id>`; otherwise
    refuses (defense against accidental `git checkout` by the agent)
  - executes `git -C <worktree> add -A && git -C <worktree> commit -m <message>`
  - calls `update-pbi-head.sh <pbi-id>` to mirror new `head_sha`
    into `state.json`

### 5.3 Completion handoff

When `pbi-pipeline` reaches its existing `phase = complete` state,
the Developer:

1. Computes `paths_touched = git -C <worktree> diff --name-only <base_sha>..HEAD`
2. Calls `.scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>` which:
   - sets `state.phase = "ready_to_merge"`
   - writes `head_sha`, `paths_touched`, `ready_at`
3. Notifies SM via Agent Teams: `[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<id> sha=<sha>`
4. Stops and waits for further SendMessage from SM

The `state.phase` value `complete` therefore becomes a transient
internal state of the pipeline. The externally observable terminal
states for a successful PBI are now:

```
ready_to_merge → merged → review_complete
```

## 6. Merge Protocol

### 6.1 Trigger

SM, on receiving `[<pbi-id>] PBI_READY_TO_MERGE`, immediately
invokes the new `pbi-merge` skill, which calls
`.scrum/scripts/merge-pbi.sh <pbi-id>`. Priority equals
`pbi-escalation-handler`: SM does no other coordination work until
this finishes.

If multiple PBIs are ready simultaneously, SM processes them in
**receive order, strictly serialized**. The wrapper internally
acquires a `flock` on the main worktree to make double-invocation
safe.

### 6.2 merge-pbi.sh procedure

All steps execute against the **main worktree**, not inside the PBI
worktree.

1. Pre-conditions
   - `pbi/<id>/state.json.phase == "ready_to_merge"`
   - branch `pbi/<id>` exists
   - `git status --porcelain` on main worktree is empty
2. Capture pre-merge state
   - `PRE_HEAD = git rev-parse HEAD`
3. Merge
   - `git checkout main`
   - `git merge --no-ff pbi/<pbi-id> -m "merge: <pbi-id>"`
   - on conflict → §6.3 (a)
4. Verify artifacts
   - For each path in `paths_touched`:
     `git ls-files --error-unmatch -- "<path>"` must succeed
   - failure → §6.3 (b)
5. Verify build / tests
   - run `hooks/quality-gate.sh` against the merged HEAD (it
     already scopes to changed files)
   - non-zero → §6.3 (c)
6. Commit success
   - `merged_sha = git rev-parse HEAD`
   - call `.scrum/scripts/mark-pbi-merged.sh <pbi-id> <merged_sha>`,
     which sets:
     - `state.phase = "merged"`, `state.merged_sha`, `state.merged_at`
     - mirrors `merged_sha` and `merged_at` into `backlog.json items[]`
7. Cleanup
   - `git worktree remove .scrum/worktrees/<pbi-id>`
   - `git branch -d pbi/<pbi-id>` (must follow worktree removal)
8. Notify Developer: `[<pbi-id>] MERGED at <sha>. Stand by for next assignment.`

### 6.3 Failure modes

Common rollback for all three: `git reset --hard $PRE_HEAD` to
return main to its pre-merge state. The PBI worktree and branch
remain so the Developer can iterate.

(a) **Merge conflict**
- `state.phase = "merge_conflict"`,
  `state.merge_failure = { kind: "conflict", paths: [<conflicting>], pre_head_at_failure }`
- SM SendMessage:
  `[<pbi-id>] MERGE_CONFLICT paths=[...]. Rebase pbi/<id> onto main HEAD <sha>, fix, re-notify PBI_READY_TO_MERGE.`
- Developer rebases inside the worktree, resolves conflicts,
  re-marks ready_to_merge, SM re-runs `merge-pbi.sh`

(b) **Artifact missing** — `paths_touched` declares files that are
not present at HEAD after the merge succeeded
- `state.phase = "merge_artifact_missing"`,
  `state.merge_failure = { kind: "artifact_missing", paths: [<missing>] }`
- SM SendMessage:
  `[<pbi-id>] ARTIFACT_MISSING paths=[...]. Re-add files to pbi/<id> branch (likely lost during a rebase or .gitignore mishap), re-notify PBI_READY_TO_MERGE.`
- Developer fixes on branch and re-marks ready_to_merge

(c) **Quality-gate regression**
- `state.phase = "merge_regression"`,
  `state.merge_failure = { kind: "regression", report_path }`
- SM SendMessage:
  `[<pbi-id>] MERGE_REGRESSION. Failed checks: <summary>. Fix on pbi/<id>, re-notify.`
- Developer fixes on branch and re-marks ready_to_merge

### 6.4 Repeated-failure escalation

`mark-pbi-merge-failure.sh` increments
`state.merge_failure_count`. On the **third consecutive failure**
for the same PBI (any kind), the same wrapper sets
`state.phase = "escalated"` instead of a `merge_*` value. Per the
existing escalation contract, the projection sets
`backlog.json items[].status = "blocked"` and SM is expected to
invoke `pbi-escalation-handler`. A successful merge resets the
counter.

The "rebase onto main HEAD <sha>" instruction in the SendMessage
templates means the **main worktree's current HEAD** at the moment
SM sends the message:
`git -C <pbi-worktree> rebase $(git -C <main-worktree> rev-parse HEAD)`.
The Developer must not invoke `git fetch` or rely on a remote
`main` ref; this design is local-only.

## 7. State Schema

### sprint.json (added)

```json
{
  "base_sha": "<commit at Sprint start>",
  "base_sha_captured_at": "<ISO>"
}
```

### pbi/<pbi-id>/state.json (added / extended)

`phase` enum extended:

| Value | Meaning |
|---|---|
| design / impl_ut | (existing) pipeline running |
| complete | (existing, now transient) pipeline done, pre-handoff |
| escalated | (existing) pipeline gave up |
| ready_to_merge | (new) Developer has handed off, awaiting SM merge |
| merged | (new) merged into main |
| merge_conflict | (new) merge attempt hit conflicts |
| merge_artifact_missing | (new) merge succeeded but `paths_touched` not on HEAD |
| merge_regression | (new) merge succeeded but tests/lint failed |
| review_complete | (existing) cross-review accepted |

New fields:

```json
{
  "branch":             "pbi/<pbi-id>",
  "worktree":           ".scrum/worktrees/<pbi-id>",
  "base_sha":           "<= sprint.base_sha at creation>",
  "head_sha":           "<latest commit on the PBI branch>",
  "paths_touched":      ["src/...", "tests/..."],
  "ready_at":           "<ISO>",
  "merged_sha":         "<merge commit SHA on main>",
  "merged_at":          "<ISO>",
  "merge_failure": {
    "kind":               "conflict" | "artifact_missing" | "regression",
    "paths":              ["..."],         // conflict / artifact_missing
    "report_path":        ".scrum/pbi/<id>/quality-gate-out.log",  // regression
    "pre_head_at_failure":"<sha>"
  },
  "merge_failure_count": 0
}
```

### backlog.json items[] (added)

```json
{
  "merged_sha": "<sha>",
  "merged_at":  "<ISO>"
}
```

### Status projection (`update-pbi-state.sh`)

| state.phase | items[].status |
|---|---|
| design / impl_ut | in_progress |
| complete | review |
| ready_to_merge | review |
| merged | review |
| merge_conflict / merge_artifact_missing / merge_regression | review |
| escalated | blocked |
| review_complete | done |

## 8. Affected Files

### New

- `skills/pbi-merge/SKILL.md` — SM-side merge skill
- `scripts/scrum/freeze-sprint-base.sh`
- `scripts/scrum/create-pbi-worktree.sh`
- `scripts/scrum/commit-pbi.sh`
- `scripts/scrum/update-pbi-head.sh`
- `scripts/scrum/mark-pbi-ready-to-merge.sh`
- `scripts/scrum/merge-pbi.sh`
- `scripts/scrum/mark-pbi-merged.sh`
- `scripts/scrum/mark-pbi-merge-failure.sh` — sets one of
  `merge_conflict` / `merge_artifact_missing` / `merge_regression`,
  records `merge_failure`, increments `merge_failure_count`, and
  promotes to `phase = "escalated"` when count reaches 3
- `scripts/scrum/cleanup-pbi-worktree.sh`
- `hooks/pre-tool-use-no-branch-ops.sh` — blocks
  `git checkout -b`, `git switch -c`, `git branch <new>`,
  `git push`, direct `git merge`, direct `git rebase` from
  Bash unless the command starts with `.scrum/scripts/`
- `tests/unit/scrum-state/test_*.bats` for each new wrapper
- `tests/unit/hooks/test_pre-tool-use-no-branch-ops.bats`

### Modified

- `agents/developer.md`
  - Strict Rules: PBI worktree only; commits via wrapper; branch ops forbidden
  - State Files: list new fields
- `agents/scrum-master.md`
  - Allowed: explicitly mention `.scrum/scripts/*` wrappers (state + git)
  - Workflow: handle `[<pbi-id>] PBI_READY_TO_MERGE` with priority equal to escalation
  - Note serial processing of concurrent ready-to-merge
  - skills list: add `pbi-merge`
- `skills/spawn-teammates/SKILL.md`
  - Step 0: `freeze-sprint-base.sh`
  - Step 5.5: `create-pbi-worktree.sh` per PBI
  - Step 8: include absolute worktree path + `cd` instruction in task prompt
- `skills/pbi-pipeline/SKILL.md`
  - Outputs: commits go to PBI branch in PBI worktree via wrapper
  - Phases: replace `[Completion]` with handoff (`mark-pbi-ready-to-merge` + notify + wait)
  - Exit Criteria: `phase = ready_to_merge` (or `escalated`)
- `skills/pbi-pipeline/references/state-management.md`
  - new field schema and projection table
- `skills/cross-review/SKILL.md`
  - Precondition: all Sprint PBIs at `phase ∈ {merged, escalated}`.
    SM must drive any `ready_to_merge` / `merge_*` PBI to one of
    those terminal states (via `pbi-merge` or escalation handler)
    before invoking `cross-review`
  - Review target: merged main HEAD (only the merged PBIs)
- `skills/sprint-planning/SKILL.md`
  - Note that physical worktree isolation makes catalog-only pre-separation sufficient
- `hooks/pre-tool-use-scrum-state-guard.sh`
  - Verify all new fields are wrapper-only writable (likely covered by existing logic; confirm)
- `scripts/setup-user.sh`
  - Deploy new wrappers to `.scrum/scripts/`
  - Register `pre-tool-use-no-branch-ops.sh` in target settings.json
- `docs/MIGRATION-scrum-state-tools.md`
  - Add new wrappers to the field-to-wrapper map
- `docs/contracts/scrum-state/*.json` (if schema is SSOT)
  - Update sprint, PBI state, backlog item schemas
- `CLAUDE.md`
  - New “Git Workflow” section: PBI worktree + branch convention,
    SM merge responsibility
  - Update State management section with new fields

### Untouched

- `hooks/quality-gate.sh` — already scopes by `git merge-base`; works as-is

## 9. Migration

1. Implement wrappers, hook, tests (no impact on running Sprints)
2. Update agents and skills (text only)
3. Bump deploy via `setup-user.sh`
4. Apply from the **next** Sprint. Current Sprint completes under
   the existing implicit workflow
5. Run one Sprint end-to-end with the new workflow
6. Record observations in `improvements.json`. If silent loss is
   eliminated and no new failure modes appear, harden by extending
   the no-branch-ops hook scope; otherwise iterate

## 10. Open Risks

- **`hooks/lib/validate.sh` uses relative `.scrum/`** — through the
  symlink this resolves correctly, but must be confirmed against
  every script that opens state files
- **Permission of SM to run wrappers** — currently
  `agents/scrum-master.md` forbids running tests; must be amended
  carefully so the exception is bounded to `.scrum/scripts/*`
- **Stale worktree on crash** — if `merge-pbi.sh` is interrupted
  between merge and cleanup, a worktree whose branch is already
  merged remains. `cleanup-pbi-worktree.sh` must be idempotent and
  safe to call manually
- **PBI re-spawn after partial commits** — when a Developer is
  re-spawned, the existing `pbi/<id>` branch may already have
  commits. The pipeline must read `head_sha` from `state.json`
  rather than assume a clean branch
