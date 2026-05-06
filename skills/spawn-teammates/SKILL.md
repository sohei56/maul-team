---
name: spawn-teammates
description: >
  Reproducible teammate creation during Sprint Planning.
  Reads Sprint and Backlog state, spawns Developer teammates
  via Agent Teams with consistent naming and assignment.
disable-model-invocation: false
---

## Inputs

- `sprint.json` → pbi_ids, developer_count
- `backlog.json` → Sprint PBIs

## Outputs

- `sprint.json` → developers[] populated, status: "active"
- Agent Teams teammates spawned

## Preconditions

- state.json phase: "sprint_planning" or "integration_sprint"
- sprint.json status: "planning", pbi_ids set
- backlog.json PBIs status: refined matching pbi_ids

## Steps

0. **Freeze Sprint base.** Run
   `bash .scrum/scripts/freeze-sprint-base.sh`. This captures
   `sprint.json.base_sha = $(git rev-parse HEAD)` exactly once per
   Sprint. PBI worktrees fork from this commit.

1. Read sprint.json→developer_count, pbi_ids
2. Read backlog.json→PBI details
3. developer_count = min(Sprint refined PBIs, 6). **1 Developer = 1 PBI**
4. Extract Sprint number N from sprint.json id (e.g., "sprint-001"→1)
5. Each Developer:
   a. ID: `dev-001-s{N}`, `dev-002-s{N}` (zero-pad + -s{N} mandatory, no short forms)
   b. Implement assignment from backlog.json implementer_id
   c. Entry: `{"id": "dev-001-s{N}", "assigned_work": {"implement": [...]}, "status": "active", "sub_agents": []}`

5.5. **Create PBI worktrees.** For each PBI assigned in this Sprint
     run:
     ```
     bash .scrum/scripts/create-pbi-worktree.sh <pbi-id>
     ```
     This creates `.scrum/worktrees/<pbi-id>` checked out at
     `pbi/<pbi-id>` forked from `sprint.base_sha`, sets up the
     `.scrum` symlink, and writes `branch`, `worktree`, `base_sha`
     into `.scrum/pbi/<pbi-id>/state.json`.

6. **Reconcile backlog.json**: Update all PBI implementer_id to match final dev-NNN-sN IDs
7. Update sprint.json→developers[] + developer_count (TUI dashboard reads both)
8. Spawn Agent Teams teammates (agents/developer.md). Name = exact ID
   from 5a. Compute `PROJECT_ROOT=$(git rev-parse --show-toplevel)` at
   spawn time and substitute it into the task prompt below in place of
   `<PROJECT_ROOT>`. Each Developer's `<pbi-id>` is the one assigned to
   them in 5a/6.

   Task:
   ```
   Your working directory: <PROJECT_ROOT>/.scrum/worktrees/<pbi-id>
   First action: cd "<PROJECT_ROOT>/.scrum/worktrees/<pbi-id>"
   All file operations and commits must stay inside this directory.
   Use `.scrum/scripts/commit-pbi.sh` for commits — never raw `git commit`.

   Invoke the `pbi-pipeline` skill to drive design → impl+UT → per-PBI
   review for your assigned PBI. Do NOT invoke `cross-review` — that is
   a Sprint-end skill owned by the Scrum Master (FR-009 Layer 2).

   When pbi-pipeline finishes the UT Run stage successfully, run
   `.scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>` (this sets
   backlog status to `in_progress_merge`) and notify SM:
   `[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<pbi-id> sha=<head>`.
   Then stop and wait.
   ```
9. Verify all teammates active + assignments received
10. sprint.json → status: "active"

Ref: FR-007

## Re-Spawn Recovery (FR-022)

When Teammate Liveness Protocol detects terminated Developer:

1. Read `sprint.json`→get developer entry + assigned_work
2. Read `backlog.json`→get PBI status to determine remaining work
3. Update `sprint.json` developer status: "failed"
4. Spawn new teammate: same ID (e.g., `dev-001-s{N}`), `agents/developer.md`
5. Task prompt = remaining work only (always via `pbi-pipeline`).
   Branch on the PBI's backlog status:
   - `refined` (not yet started) → "Invoke pbi-pipeline for PBI-XXX from the start"
   - `in_progress_design` → "Resume pbi-pipeline for PBI-XXX from the Design stage; prior design docs at: ..."
   - `in_progress_impl` / `in_progress_pbi_review` / `in_progress_ut_run` → "Resume pbi-pipeline for PBI-XXX from the impl→pbi_review→ut_run cycle; design docs at: ..."
   - `in_progress_merge` → "Re-run `mark-pbi-ready-to-merge.sh` and re-notify SM; the prior worktree is intact"
   - cross-review FAIL (status reverted to `in_progress_impl`) → "Fix cross-review findings for PBI-XXX: [findings]. Source at: ... Then re-run UT and re-mark ready-to-merge"
6. Update `sprint.json` developer status: "active"

## Exit Criteria

- sprint.json developers[] = developer_count entries
- All Developers: assigned_work.implement[] non-empty
- All teammates spawned + active
- sprint.json status: "active"
