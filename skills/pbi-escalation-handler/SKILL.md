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
    worktree preserved). **kind=docs PBIs retry to `in_progress_impl`
    instead** — design was never run — with `design_status` and
    `coverage_status` reset to `skipped` (not `pending`) and
    `ut_status` left at `pending`. See § Steps step 4.
  - **hold** / **human-escalate** → stays at `escalated` (until the
    blocking condition clears, at which point SM moves it to
    `in_progress_design` to resume; worktree preserved for inspection)
  - **block on external dependency** → `blocked` (SM-only status; later
    transitioned back to `in_progress_design` when the external factor
    clears; worktree preserved)
  - **abandon** → `cancelled` (terminal); SM calls
    `cleanup-pbi-worktree.sh` to remove the worktree + `pbi/<id>`
    branch. The audit trail lives in `escalation-resolution.md`, not
    in a lingering `escalated` status.
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
| `catalog_lock_timeout` | Check `.scrum/locks/` for a stale `catalog-<spec_id>.lock.d` directory. If the holder Developer is dead, force-release (`rmdir` the stale lock dir) and retry (status → `in_progress_design`). Else human-escalate. |
| `reviewer_unavailable` | The conductor already attempted a single general-purpose-agent retry inside the pipeline. Re-spawn the reviewer sub-agent with the conductor's `codex_is_available` preflight forced to the alternate model path (codex→opus or vice versa) and retry (status → `in_progress_design`). If the alternate path also fails, human-escalate. |
| `stale_review_snapshot` | Reviewer signed off against an out-of-date SHA. Refresh the pinned `base_sha` / `head_sha` on the affected pipeline.log entry and retry the same Round (status → `in_progress_design`). No human needed unless the snapshot drift recurs ≥ 2 times — then human-escalate. |
| `merge_conflict` | Diagnose conflict scope; for trivial cases redirect Developer back to fix on `pbi/<id>` (manual SendMessage; status remains `escalated` until the `mark-pbi-ready-to-merge.sh` round flips it back to `in_progress_merge`). **Before re-notifying, run the partial merge-failure reset only** — `.scrum/scripts/update-pbi-state.sh "$PBI" merge_failure_count 0 merge_failure null` (do NOT run the Step 4 full reset; it zeroes round counters and flips status to `in_progress_design`). Otherwise `mark-pbi-merge-failure.sh` increments from the stale ≥3 count and the PBI re-escalates on the very next merge failure. For structural conflicts, human-escalate. |
| `merge_artifact_missing` | Confirm whether files were intentionally removed. If unintentional, ask Developer to re-add. If intentional, human-escalate to update `paths_touched`. |
| `merge_regression` | Read `.scrum/pbi/<pbi-id>/merge-regression.log` to identify the failing test(s). If the failure is in the PBI's own scope, present user with options [split / redesign / hold]. If it crosses PBI boundaries (regression in unrelated code), human-escalate — likely needs PO decision on park vs. revert. |

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, every Response Matrix
row that would "present the user with options" or "human-escalate"
re-targets the same decision to the `product-owner` teammate via
`SendMessage`. The matrix actions themselves are unchanged — only
the PO seat. See `rules/scrum-context.md` § PO seat resolution and
`agents/product-owner.md` § Communication protocol for the canonical
shapes; this section is a no-op when `po_mode` is absent or `"human"`.

Override map (apply per row of the Response Matrix above):

| Matrix row | `po_mode=agent` resolution |
|---|---|
| `stagnation` / `divergence` (the "options [split / redesign / hold]" prompt) | `[<pbi-id>] PO_DECISION_REQUEST kind=escalation_choice options=[split,redesign,hold] recommendation=<sm-preferred>` — SM's `recommendation` is mandatory (engineering view of the failure mode). |
| `merge_regression` **when the failing test sits in the PBI's own scope** (the "options [split / redesign / hold]" prompt) | Same as stagnation: `kind=escalation_choice options=[split,redesign,hold] recommendation=<...>`. |
| `merge_regression` **crossing PBI boundaries** (regression in unrelated code) | `kind=escalation_choice options=[revert,park] recommendation=<...>` — `park` writes the PBI to `.scrum/po/attention.md` and flips status to `blocked`; `revert` rolls the merge back per the matrix's existing semantics. |
| `requirements_unclear` ("SM consults PO via clarification ticket") | `kind=spec_clarification` — the existing "SM consults PO" wording already names the PO seat; in agent mode the PO is the product-owner teammate, reached by SendMessage. |
| `coverage_tool_unavailable` (the "surface install instruction to user" step) | `kind=escalation_choice options=[install,park] recommendation=install` — on `install`, SM delegates the install to the responsible Developer (no human in the loop). If install is impossible (org-level permission, paid license, network restriction), the PO appends a numbered entry to `.scrum/po/attention.md` and SM flips the PBI to `blocked`. |
| `coverage_tool_error`, `catalog_lock_timeout` → human-escalate branches | `kind=escalation_choice options=[retry-once,descope-split,park] recommendation=<...>` — `park` writes to `.scrum/po/attention.md` and flips the PBI to `blocked`; **the team does not idle waiting for a human**. |
| `reviewer_unavailable` → human-escalate branch (alternate model also failed) | `kind=escalation_choice options=[retry-once,descope-split,park] recommendation=<...>`. Same `park` semantics. |
| `stale_review_snapshot` → human-escalate branch (drift recurred ≥ 2 times) | `kind=escalation_choice options=[retry-once,descope-split,park] recommendation=<...>`. Same `park` semantics. |
| `max_rounds` / `budget_exhausted` → human-escalate branches | Same shape: `kind=escalation_choice options=[retry-once,descope-split,park] recommendation=<...>`. |
| `merge_conflict` / `merge_artifact_missing` "human-escalate" branches | `kind=escalation_choice options=[retry-once,descope-split,park] recommendation=<...>`. `park` again routes to `.scrum/po/attention.md` + status `blocked`, never to a blocking human wait. |

Rules common to every row above:

- The SM **must include `recommendation=<...>`** in every
  `PO_DECISION_REQUEST` — the engineering view of the right next
  step. The PO may override but the log must show whether the PO
  agreed.
- The PO reply `[<pbi-id>] PO_DECISION kind=<kind>
  decision=choice:<label> dec_id=<dec-NNNN> rationale=<...>` is
  persisted by `.scrum/scripts/append-po-decision.sh`. **Both** the
  per-PBI `escalation-resolution.md` (audit trail above) **and** the
  PO decision log (`.scrum/po/decisions.json`, addressed by
  `dec_id`) record the outcome; the resolution file should cite the
  matching `dec_id`.
- A `park` verdict **must not** stall the autonomy loop. The PBI's
  backlog status moves to `blocked`, the PO writes the human review
  item to `.scrum/po/attention.md`, and the SM continues with the
  next available work. The human picks up `attention.md` at their
  next review window; resumption (status → `in_progress_design`) is
  driven by a later PO decision once the human resolves the parked
  item.

## Steps

1. Read `state.json` for the PBI id.
2. Identify `escalation_reason`.
3. Match to Response Matrix action.
4. **For retry** (e.g. `stagnation` after user picks `redesign`,
   `requirements_unclear` after PO answer, `catalog_lock_timeout`
   after stale-lock cleanup): spawn fresh Developer instance for the
   PBI; reset round counters, per-stage flags, `merge_failure_count`,
   and the `merge_failure` object (so a retried PBI starts merge
   attempts at strike 0 *and* dashboards/gates do not see a stale
   failure record), then flip backlog status:
   ```bash
   .scrum/scripts/update-pbi-state.sh "$PBI_ID" \
     escalation_reason null \
     design_round 0 impl_round 0 \
     design_status pending impl_status pending \
     ut_status pending coverage_status pending \
     merge_failure_count 0 \
     merge_failure null
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_design
   ```
   **kind=docs PBIs** (`backlog.json items[].kind == "docs"`) reset and
   resume differently — design and coverage never ran, so their
   `*_status` carry `skipped`, `ut_status` stays `pending`, and the
   resume status is `in_progress_impl` (design is not the failed stage).
   Canonical: `docs/data-model.md` § kind=docs status semantics.
   ```bash
   .scrum/scripts/update-pbi-state.sh "$PBI_ID" \
     escalation_reason null \
     design_round 0 impl_round 0 \
     design_status skipped impl_status pending \
     ut_status pending coverage_status skipped \
     merge_failure_count 0 \
     merge_failure null
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
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
   worktree + `pbi/<id>` branch, then
   `.scrum/scripts/update-backlog-status.sh "$PBI_ID" cancelled`.
   `cancelled` is terminal; the decision and reasoning are preserved
   in `escalation-resolution.md` (step 7), never by parking the PBI
   at `escalated` or mislabeling it `done`. SM owns this cleanup —
   neither merge-pbi nor the Developer ever cleans up an escalated
   worktree.
7. Write decision to `.scrum/pbi/<pbi-id>/escalation-resolution.md`
   with timestamp, decision, and reasoning.

## Exit Criteria

- `escalation-resolution.md` exists for the PBI
- backlog.json `items[].status` reflects decision
  (`in_progress_design` for retry — `in_progress_impl` for a kind=docs
  retry, `escalated` for hold, `blocked` for
  parked-on-external-dependency, `cancelled` for abandon)
- User informed (when human-escalate or hold)
