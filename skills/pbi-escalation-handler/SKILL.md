---
name: pbi-escalation-handler
description: >
  Handles PBI pipeline escalation notifications from Developer. Reads
  escalation context, applies response matrix (retry / split / hold /
  human), and routes to user when human intervention is needed.
disable-model-invocation: false
---

## Inputs

- Notification from Developer (Agent Teams) with PBI id and
  `escalation_reason`. Backlog `items[].status` for the PBI is
  `escalated`.
- `.scrum/pbi/<pbi-id>/state.json` (`escalation_reason`, round counters,
  per-stage `*_status`)
- Latest review files: `.scrum/pbi/<pbi-id>/{design,impl,ut}/review-r{last}.md`
- `.scrum/pbi/<pbi-id>/metrics/*.json`

## Outputs

- SM judgment recorded at
  `.scrum/pbi/<pbi-id>/escalation-resolution.md` (audit trail)
- backlog.json `items[].status` updated via
  `update-backlog-status.sh`:
  - **retry** → `in_progress_design` (round counters, per-stage
    `*_status` flags, and `merge_failure_count` reset on `state.json`;
    worktree preserved)
  - **hold** / **human-escalate** → stays at `escalated` (until the
    blocking condition clears, at which point SM moves it to
    `in_progress_design` to resume; worktree preserved for inspection)
  - **block on external dependency** → `blocked` (SM-only status; later
    transitioned back to `in_progress_design` when the external factor
    clears; worktree preserved)
  - **abandon** → SM calls `cleanup-pbi-worktree.sh` to remove the
    worktree + `pbi/<id>` branch; backlog status stays `escalated`
    unless the user explicitly reclassifies (e.g., to `done`)
- User notified via SM channel when human escalation is needed

## Response Matrix

| escalation_reason | Action |
|---|---|
| `stagnation` | Extract Critical/High findings → present user with options [split / redesign / hold] |
| `divergence` | Same as stagnation; mark urgent. (rollback is future work) |
| `max_rounds` | Inspect findings count trend across rounds. If decreasing, propose 1-time retry with fresh Developer. Else human-escalate. |
| `budget_exhausted` | Immediate human-escalate |
| `requirements_unclear` | SM consults PO via clarification ticket; on PO answer, retry (status → `in_progress_design`) and re-spawn Developer to resume PBI |
| `coverage_tool_unavailable` | Surface install instruction (e.g. `pip install coverage`) to user; PBI on hold (status stays `escalated`, or move to `blocked`) until installed |
| `coverage_tool_error` | Inspect last pipeline.log entries for the tool error; surface to user; hold |
| `catalog_lock_timeout` | Check `.scrum/locks/` for stale lock holders. If holder Developer is dead, force-release and retry (status → `in_progress_design`). Else human-escalate. |
| `merge_conflict` | Diagnose conflict scope; for trivial cases redirect Developer back to fix on `pbi/<id>` (manual SendMessage; status remains `escalated` until the `mark-pbi-ready-to-merge.sh` round flips it back to `in_progress_merge`). For structural conflicts, human-escalate. |
| `merge_artifact_missing` | Confirm whether files were intentionally removed. If unintentional, ask Developer to re-add. If intentional, human-escalate to update `paths_touched`. |
| `merge_regression` | Read `.scrum/pbi/<pbi-id>/merge-regression.log` to identify the failing test(s). If the failure is in the PBI's own scope, present user with options [split / redesign / hold]. If it crosses PBI boundaries (regression in unrelated code), human-escalate — likely needs PO decision on park vs. revert. |

## Steps

1. Read `state.json` for the PBI id.
2. Identify `escalation_reason`.
3. Match to Response Matrix action.
4. **For retry** (e.g. `stagnation` after user picks `redesign`,
   `requirements_unclear` after PO answer, `catalog_lock_timeout`
   after stale-lock cleanup): spawn fresh Developer instance for the
   PBI; reset round counters, per-stage flags, and `merge_failure_count`
   (so a retried PBI starts merge attempts at strike 0), then flip
   backlog status:
   ```bash
   .scrum/scripts/update-pbi-state.sh "$PBI_ID" \
     escalation_reason null \
     design_round 0 impl_round 0 \
     design_status pending impl_status pending \
     ut_status pending coverage_status pending \
     merge_failure_count 0
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_design
   ```
   The existing worktree at `.scrum/worktrees/<pbi-id>/` is preserved —
   the fresh Developer resumes on the same branch (no `cleanup-pbi-worktree.sh`).
5. **For hold or human-escalate**: prepare summary message (PBI id, last
   review headlines, `escalation_reason`, recommended user actions);
   send via SM communications channel. Backlog status remains
   `escalated` (or move to `blocked` if SM is parking the PBI awaiting
   external resolution). Worktree is preserved for inspection.
6. **For abandon** (user decides the PBI is no longer viable): call
   `.scrum/scripts/cleanup-pbi-worktree.sh "$PBI_ID"` to remove the
   worktree + `pbi/<id>` branch. Backlog status stays `escalated` as
   the audit trail; flip to `done` only if the user explicitly
   reclassifies the PBI as resolved. SM owns this cleanup — neither
   merge-pbi nor the Developer ever cleans up an escalated worktree.
7. Write decision to `.scrum/pbi/<pbi-id>/escalation-resolution.md`
   with timestamp, decision, and reasoning.

## Exit Criteria

- `escalation-resolution.md` exists for the PBI
- backlog.json `items[].status` reflects decision
  (`in_progress_design` for retry, `escalated` for hold,
  `blocked` for parked-on-external-dependency)
- User informed (when human-escalate or hold)
