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
- backlog.json `items[].status` for this PBI (must be `in_progress_merge`)
- `.scrum/pbi/<pbi-id>/state.json` (head_sha, paths_touched, ready_at populated)
- `.scrum/sprint.json.developers[]` (to find the Developer to message)
- `.scrum/config.json` (optional) — `merge_regression.command` is a
  single shell string run via `bash -c` from the main repo root after
  the merge commit lands. Absent / empty / null → the regression gate
  is skipped and a `WARN: no merge regression command configured` line
  is printed; in `po_mode=agent`, `merge-pbi.sh` additionally appends
  a once-per-Sprint entry to `.scrum/po/attention.md` so the skipped
  gate cannot stay silent across an autonomous run (a target project
  merged a broken test suite to main repeatedly because the WARN had
  no reader). Output (stdout+stderr) is captured to
  `.scrum/pbi/<pbi-id>/merge-regression.log` (overwritten per attempt).

## Outputs

- backlog.json `items[].status` transitions to one of:
  - `awaiting_cross_review` (success — written by `mark-pbi-merged.sh`)
  - `in_progress_merge` (recoverable failure under the 3-strike threshold;
    `mark-pbi-merge-failure.sh` records `state.merge_failure.kind ∈
    {conflict, artifact_missing, regression}` but leaves backlog status
    untouched so the Developer can fix on `pbi/<id>` and re-notify).
    Status stays `in_progress_merge` across retries; each
    `mark-pbi-ready-to-merge.sh` re-notification re-stamps `head_sha`,
    `paths_touched`, and `ready_at`.
  - `escalated` (3rd consecutive failure — `mark-pbi-merge-failure.sh`
    sets `escalation_reason ∈ {merge_conflict, merge_artifact_missing,
    merge_regression}` and `pbi-escalation-handler` takes over).
- backlog.json `items[].merged_sha` mirrored on success
- Worktree `.scrum/worktrees/<pbi-id>` removed on success
- Sprint-level state untouched

## Preconditions

- SM has just received `[<pbi-id>] PBI_READY_TO_MERGE` from a Developer
- backlog.json `items[].status == "in_progress_merge"` for this PBI
- Main worktree has no tracked-file changes **on the paths this merge
  would modify**. The check is merge-scoped (`merge_colliding_dirt` in
  `lib/git-guards.sh`): tracked drift that is *disjoint* from the merge's
  file set does **not** block — it is stashed across the merge and
  restored afterward (a post-merge rollback `git reset --hard` cannot eat
  it). Drift that *intersects* the merge's file set still aborts with
  `E_INVALID_ARG` (git would refuse to overwrite it anyway). `.scrum/` is
  untracked by design; the wrapper additionally asserts `.scrum/` is **not
  tracked at all** (`assert_scrum_untracked`) and aborts if a stray commit
  ever made it tracked.

## Steps

1. **Acquire lock by serial processing.** If another `pbi-merge` skill
   invocation is in flight (multiple ready-to-merge notifications
   arrived close together), do not run them in parallel. Process them
   in receive order. The wrapper itself uses an `mkdir`-based directory
   lock at `.scrum/.locks/merge.lock.d` as a backstop (portable across
   macOS / Linux; `flock(2)` is unavailable on stock macOS).

2. **Run the wrapper:**
   ```
   bash .scrum/scripts/merge-pbi.sh <pbi-id>
   ```

3. **Branch on exit code:**
   - exit 0 → re-read `state.json`, find `merged_sha`. Backlog status
     is now `awaiting_cross_review`. SendMessage to Developer
     (`sprint.json.developers[].current_pbi == <pbi-id>`):
     `[<pbi-id>] MERGED at <merged_sha>. Stand by for next assignment.`
   - non-zero → re-read `state.json.merge_failure.kind` (status remains
     `in_progress_merge` while `merge_failure_count < 3`). The
     wrapper's main-state cleanup differs by kind: `conflict` aborts
     the merge via `git merge --abort` so main stays exactly where it
     was; `artifact_missing` and `regression` both have a partial
     merge commit on main that is rolled back via
     `git reset --hard <pre-merge HEAD>`. The SM does not need to
     redo any git operation on main — only the per-kind SendMessage
     below.
     - `conflict` → SM runs
       `bash .scrum/scripts/merge-main-into-pbi.sh <pbi-id>` to merge
       main HEAD into the PBI worktree. If that wrapper also exits
       non-zero, the worktree is left in mid-merge state and SM
       SendMessages the Developer:
       `[<pbi-id>] MERGE_CONFLICT paths=[<state.merge_failure.paths>]. Resolve conflicts in .scrum/worktrees/<pbi-id>, then run commit-pbi.sh and mark-pbi-ready-to-merge.sh. Do NOT use raw git rebase — it is blocked by pre-tool-use-no-branch-ops.`
       (If `merge-main-into-pbi.sh` succeeded cleanly, SM instructs the
       Developer to re-run `mark-pbi-ready-to-merge.sh` to re-stamp
       `head_sha` / `paths_touched` and re-notify.)
     - `artifact_missing` → SendMessage:
       `[<pbi-id>] ARTIFACT_MISSING paths=[<state.merge_failure.paths>]. Re-add files on pbi/<pbi-id> via commit-pbi.sh (files likely lost during conflict resolution or .gitignore drift), re-notify PBI_READY_TO_MERGE.`
     - `regression` → main has been rolled back to pre-merge HEAD, so
       `merge-main-into-pbi.sh` would only bring pre-merge main forward
       and **cannot reproduce** the post-merge state the regression
       command actually ran against. The Developer reproduces the
       failure from the captured log instead. SendMessage:
       `[<pbi-id>] MERGE_REGRESSION log=.scrum/pbi/<pbi-id>/merge-regression.log. Reproduce/fix in .scrum/worktrees/<pbi-id> using the regression log (main was rolled back to pre-merge HEAD, so the post-merge state cannot be replayed locally), then commit-pbi.sh and mark-pbi-ready-to-merge.sh to re-notify.`
     - 3rd consecutive failure of any kind (status flips to `escalated`,
       `merge_failure_count >= 3`, `escalation_reason ∈ {merge_conflict,
       merge_artifact_missing, merge_regression}`) → invoke
       `pbi-escalation-handler` skill with `<pbi-id>` (further Developer
       iteration is unproductive).

   Note: `merge_failure.kind` uses unprefixed values (`conflict`,
   `artifact_missing`, `regression`) while `escalation_reason` uses the
   `merge_*` prefix (`merge_conflict`, `merge_artifact_missing`,
   `merge_regression`). The mapping is one-to-one;
   `mark-pbi-merge-failure.sh` writes both.

   Throughout the recovery loop the backlog status remains
   `in_progress_merge`. The Developer fixes on `pbi/<pbi-id>` (in the
   PBI worktree), runs `commit-pbi.sh` to record the fix, then
   `mark-pbi-ready-to-merge.sh` to re-stamp `head_sha` / `paths_touched`
   / `ready_at`. SM retries `merge-pbi.sh`. The status only changes when
   the merge succeeds (→ `awaiting_cross_review`) or when the 3rd
   consecutive failure flips it to `escalated`.

4. **No further coordination work** until the merge attempt finishes
   and the Developer (if applicable) has been messaged. Receive
   priority: equal to `pbi-escalation-handler`.

## Exit Criteria

- backlog.json `items[].status ∈ {awaiting_cross_review, escalated}`
  for the PBI, and the corresponding SendMessage / handler invocation
  has been issued.

## Strict Rules

- Never invoke `git merge`, `git checkout`, `git branch`, `git rebase`,
  or `git push` directly. The wrapper handles all git operations.
- Never edit `.scrum/pbi/<id>/state.json` or write
  `backlog.json.items[].status` manually; the wrapper writes through
  `mark-pbi-*` helpers.
- Never run two `pbi-merge` invocations in parallel — even though the
  wrapper has an `mkdir`-based lock backstop, the SendMessage ordering
  depends on serial processing.
