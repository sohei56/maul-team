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
