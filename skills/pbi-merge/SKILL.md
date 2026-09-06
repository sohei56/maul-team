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
  is skipped with a WARN naming the unset `merge_regression.command`
  and pointing at `set-merge-regression-command.sh`; in
  `po_mode=agent`, `merge-pbi.sh` additionally appends
  a once-per-Sprint entry to `.scrum/po/attention.md` so the skipped
  gate cannot stay silent across an autonomous run (a target project
  merged a broken test suite to main repeatedly because the WARN had
  no reader). An explicit opt-out recorded via
  `set-merge-regression-command.sh --none` (`accepted_none`)
  suppresses both the WARN and the attention append — a single quiet
  note prints instead. Output (stdout+stderr) is captured to
  `.scrum/pbi/<pbi-id>/merge-regression.log` (overwritten per attempt).
  `detectors.timeout_seconds` bounds each guard-first detector run
  (default 120 s).
- `.scrum/audit-ledger.json` (optional) — classes at `status:
  "guarded"` carry a registered detector command that `merge-pbi.sh`
  runs against the merged tree, before the regression gate. Absent
  file or no guarded class → the gate is a silent no-op and merge
  behaviour is unchanged. Output is captured to
  `.scrum/pbi/<pbi-id>/detector-regression.log` (overwritten per
  attempt; not created when the gate is a no-op).

## Outputs

The wrapper's exit code is the routing SSOT (`0/1/2/3`; see § Steps
step 3 and the `merge-pbi.sh` header). In particular a recorded merge
failure is **exit 2** — a preflight refusal (**exit 1**) and a
post-merge bookkeeping fault (**exit 3**) are *not* merge failures and
leave `merge_failure` / `merge_failure_count` untouched.

- backlog.json `items[].status` transitions to one of:
  - `awaiting_cross_review` (success — written by `mark-pbi-merged.sh`;
    wrapper exit 0)
  - `in_progress_merge` (recoverable failure under the 3-strike threshold,
    wrapper **exit 2**; `mark-pbi-merge-failure.sh` records
    `state.merge_failure.kind ∈ {conflict, artifact_missing,
    regression, detector_regression}` but leaves backlog status
    untouched so the Developer can fix on `pbi/<id>` and re-notify).
    Status stays `in_progress_merge` across retries; each
    `mark-pbi-ready-to-merge.sh` re-notification re-stamps `head_sha`,
    `paths_touched`, and `ready_at`.
  - `escalated` (3rd consecutive failure — `mark-pbi-merge-failure.sh`
    sets `escalation_reason ∈ {merge_conflict, merge_artifact_missing,
    merge_regression, merge_detector_regression}` and
    `pbi-escalation-handler` takes over).
- backlog.json `items[].merged_sha` mirrored on success
- Worktree `.scrum/worktrees/<pbi-id>` removed on success
- Sprint-level state untouched

**Output discipline.** Follow `../../rules/scrum-context.md` § Output
discipline — lead with the outcome, no preamble, no closing recap.

## Preconditions

- SM has just received `[<pbi-id>] PBI_READY_TO_MERGE` from a Developer
- backlog.json `items[].status == "in_progress_merge"` for this PBI
- Main worktree has no tracked-file changes **on the paths this merge
  would modify**. The check is merge-scoped (`merge_colliding_dirt` in
  `lib/git-guards.sh`): tracked drift that is *disjoint* from the merge's
  file set does **not** block — it is stashed across the merge and
  restored afterward (a post-merge rollback `git reset --hard` cannot eat
  it). Drift that *intersects* the merge's file set still aborts with
  preflight exit 1 (git would refuse to overwrite it anyway). `.scrum/` is
  untracked by design; the wrapper additionally asserts `.scrum/` is **not
  tracked at all** (`assert_scrum_untracked`) and aborts if a stray commit
  ever made it tracked.

## Steps

1. **Acquire lock by serial processing.** If another `pbi-merge` skill
   invocation is in flight (multiple ready-to-merge notifications
   arrived close together), do not run them in parallel. Process them
   in receive order. The wrapper itself uses an `mkdir`-based directory
   lock at `.scrum/locks/merge.lock.d` as a backstop (portable across
   macOS / Linux; `flock(2)` is unavailable on stock macOS).

2. **Run the wrapper:**
   ```
   bash .scrum/scripts/merge-pbi.sh <pbi-id>
   ```

3. **Branch on exit code.** `merge-pbi.sh` resolves every exit to one
   of `0/1/2/3` (contract documented in the wrapper header). The exit
   code — not "zero vs non-zero" — selects the recovery: only exit 2
   is a recorded merge failure that reads `merge_failure.kind` and
   runs the 3-strike matrix.
   - exit 0 → re-read `state.json`, find `merged_sha`. Backlog status
     is now `awaiting_cross_review`. SendMessage to Developer
     (`sprint.json.developers[].current_pbi == <pbi-id>`):
     `[<pbi-id>] MERGED at <merged_sha>. Stand by for next assignment.`
   - exit 1 → **preflight / infra failure.** Nothing was recorded and
     main is unchanged (`state.merge_failure` was NOT written this
     attempt and `merge_failure_count` did NOT advance). Do **not**
     re-read `merge_failure.kind` and do **not** run the matrix below.
     Report the wrapper's stderr verbatim, fix the named precondition
     (wrong checked-out branch — recover with
     `bash .scrum/scripts/safe-switch-to-main.sh`, never raw
     `git checkout`; status ≠ `in_progress_merge`, merge
     lock contention, `.scrum/` tracked, missing state/backlog, dirty
     tree colliding with the merge set), and re-run `merge-pbi.sh`.
     This does **not** count toward the 3-strike threshold.
   - exit 2 → **a merge failure was recorded THIS attempt** and main
     is back at its pre-merge HEAD. This is the **only** exit that
     re-reads `state.json.merge_failure.kind` and runs the per-kind
     matrix + 3-strike rule. Status remains `in_progress_merge` while
     `merge_failure_count < 3`. The wrapper's main-state cleanup
     differs by kind: `conflict` aborts the merge via
     `git merge --abort` so main stays exactly where it was;
     `artifact_missing`, `detector_regression` and `regression` all
     have a merge commit on main that is rolled back via
     `git reset --hard <pre-merge HEAD>`. The SM does not need to
     redo any git operation on main — only the per-kind SendMessage
     below.
     - `conflict` → SM runs
       `bash .scrum/scripts/merge-main-into-pbi.sh <pbi-id>` to merge
       main HEAD into the PBI worktree, then branches on **that
       wrapper's own exit code** (it does not use the 0/1/2/3
       contract above):
       - `0` → merged cleanly (or main was already an ancestor).
         Instruct the Developer to re-run `mark-pbi-ready-to-merge.sh`
         to re-stamp `head_sha` / `paths_touched` and re-notify.
       - `1` → genuine conflict; the worktree is left mid-merge.
         SendMessage the Developer:
         `[<pbi-id>] MERGE_CONFLICT paths=[<state.merge_failure.paths>]. Resolve conflicts in .scrum/worktrees/<pbi-id>, then run commit-pbi.sh and mark-pbi-ready-to-merge.sh. Do NOT use raw git rebase — it is blocked by pre-tool-use-no-branch-ops.`
       - `64` / `67` (a `fail E_*` from its pre-flight guards) →
         **no `git merge` ever ran** and nothing is mid-merge. Do
         **not** send `MERGE_CONFLICT`. Relay the wrapper's stderr
         verbatim and fix the named precondition — e.g. uncommitted
         tracked changes in the PBI worktree, which the Developer
         clears via `commit-pbi.sh` — then re-run the wrapper.
     - `artifact_missing` → SendMessage:
       `[<pbi-id>] ARTIFACT_MISSING paths=[<state.merge_failure.paths>]. Re-add files on pbi/<pbi-id> via commit-pbi.sh (files likely lost during conflict resolution or .gitignore drift), re-notify PBI_READY_TO_MERGE.`
     - `regression` → main has been rolled back to pre-merge HEAD, so
       `merge-main-into-pbi.sh` would only bring pre-merge main forward
       and **cannot reproduce** the post-merge state the regression
       command actually ran against. The Developer reproduces the
       failure from the captured log instead. SendMessage:
       `[<pbi-id>] MERGE_REGRESSION log=.scrum/pbi/<pbi-id>/merge-regression.log. Reproduce/fix in .scrum/worktrees/<pbi-id> using the regression log (main was rolled back to pre-merge HEAD, so the post-merge state cannot be replayed locally), then commit-pbi.sh and mark-pbi-ready-to-merge.sh to re-notify.`
     - `detector_regression` → a guard-first audit detector fired
       (`run-detectors.sh`; see
       `../codebase-audit/references/detectors.md`). Main was rolled
       back exactly as for `regression`, so the post-merge state cannot
       be replayed locally. SendMessage:
       `[<pbi-id>] DETECTOR_REGRESSION log=.scrum/pbi/<pbi-id>/detector-regression.log. Fix in .scrum/worktrees/<pbi-id> using the log — each line is prefixed with the guarded class identity (main was rolled back to pre-merge HEAD), then commit-pbi.sh and mark-pbi-ready-to-merge.sh to re-notify.`
       The log distinguishes the two failing modes, and **both** fail
       the merge (fail-closed): violation lines mean the PBI
       reintroduced the class; a `DETECTOR COULD NOT EXECUTE` line
       means the ratchet itself is broken (exit 127, timeout, or no
       registered command). A broken ratchet is never merged around
       silently — un-guarding the class is a deliberate, ledger-audited
       act:
       `.scrum/scripts/update-audit-ledger.sh set-status --identity <identity> --status open`
       returns it to LLM audit scope. Do that only on a PO/SM decision,
       never to unblock a queue.
     - 3rd consecutive failure of any kind (status flips to `escalated`,
       `merge_failure_count >= 3`, `escalation_reason ∈ {merge_conflict,
       merge_artifact_missing, merge_regression,
       merge_detector_regression}`) → invoke `pbi-escalation-handler`
       skill with `<pbi-id>` (further Developer iteration is
       unproductive).
   - exit 3 → **the merge commit landed on main but post-merge
     bookkeeping/cleanup did not complete** (or a rollback after a
     recorded failure failed — main was mutated). The PBI is
     effectively merged; do **not** route to the failure matrix and do
     **not** count it toward the 3-strike threshold. Read the
     wrapper's stderr: it names the exact recovery — re-run
     `mark-pbi-merged.sh <pbi-id> <sha>` (backlog not yet flipped to
     `awaiting_cross_review`), re-run `cleanup-pbi-worktree.sh
     <pbi-id>` (worktree/branch left behind), or a manual check
     (verify main HEAD is at the intended merge commit when a rollback
     failed). Repair, then confirm backlog status is
     `awaiting_cross_review` and `.scrum/worktrees/<pbi-id>` +
     `pbi/<pbi-id>` are gone before moving on.

   Note: `merge_failure.kind` uses unprefixed values (`conflict`,
   `artifact_missing`, `regression`, `detector_regression`) while
   `escalation_reason` uses the `merge_*` prefix (`merge_conflict`,
   `merge_artifact_missing`, `merge_regression`,
   `merge_detector_regression`). The mapping is one-to-one;
   `mark-pbi-merge-failure.sh` writes both.

   Throughout the recovery loop the backlog status remains
   `in_progress_merge`. The Developer fixes on `pbi/<pbi-id>` (in the
   PBI worktree), runs `commit-pbi.sh` to record the fix, then
   `mark-pbi-ready-to-merge.sh` to re-stamp `head_sha` / `paths_touched`
   / `ready_at`. SM retries `merge-pbi.sh`. The status only changes when
   the merge succeeds (→ `awaiting_cross_review`) or when the 3rd
   consecutive failure flips it to `escalated`.

4. **Promote a merged detector PBI to `guarded`** — exit 0 only, and
   only when the merged PBI is a `role: detector` entry in the ledger.
   Registration happens **after** the merge commit lands, never at PBI
   done: a detector registered from the worktree names a command that
   does not exist on `main`, so every *other* PBI merging in between
   would hit exit 127 and be failed by the fail-closed gate.

   ```bash
   PBI=<pbi-id>
   IDENT="$(jq -r --arg id "$PBI" '
     .classes[]? | select(any(.pbi_ids[]?; .id == $id and .role == "detector")) | .identity
   ' .scrum/audit-ledger.json 2>/dev/null || true)"
   # Empty → not a detector PBI; skip this step entirely.
   if [ -n "$IDENT" ]; then
     SPRINT="$(jq -r '.id' .scrum/sprint.json)"
     .scrum/scripts/update-audit-ledger.sh register-detector \
       --identity "$IDENT" --command '<the command from the PBI acceptance criteria>' \
       --sprint "$SPRINT" \
     && .scrum/scripts/update-audit-ledger.sh set-status \
       --identity "$IDENT" --status guarded
   fi
   ```

   `register-detector` runs `run-detectors.sh --check` itself and
   refuses a command that cannot execute; `set-status guarded`
   re-verifies and additionally proves the deployed `merge-pbi.sh` is
   wired to the runner. **A failure here never fails the merge** — the
   merge already landed. Leave the class at `sweeping`, report the
   wrapper's stderr verbatim, and append one line to
   `.scrum/po/attention.md` naming the class and the refusal, so an
   unwired ratchet cannot be mistaken for a live one.

5. **No further coordination work** until the merge attempt finishes
   and the Developer (if applicable) has been messaged. Receive
   priority: equal to `pbi-escalation-handler`.

## Exit Criteria

One of the following outcomes holds for the PBI:

- backlog.json `items[].status ∈ {awaiting_cross_review, escalated}`,
  and the corresponding SendMessage / handler invocation has been
  issued.
- backlog.json `items[].status == "in_progress_merge"` (recoverable
  failure, `merge_failure_count < 3`), `state.merge_failure` recorded,
  and the per-kind SendMessage from step 3 issued — retry pending; the
  next `PBI_READY_TO_MERGE` re-notification triggers a fresh
  invocation.

## Strict Rules

- Never invoke `git merge`, `git checkout`, `git branch`,
  `git rebase`, `git push`, or `git worktree add -b` directly. The
  wrapper handles all git operations. This list is **team policy** and
  is deliberately wider than the machine-enforced subset — see
  `hooks/pre-tool-use-no-branch-ops.sh` for what the hook actually
  blocks.
- Never edit `.scrum/pbi/<id>/state.json` or write
  `backlog.json.items[].status` manually; the wrapper writes through
  `mark-pbi-*` helpers.
- Never run two `pbi-merge` invocations in parallel — even though the
  wrapper has an `mkdir`-based lock backstop, the SendMessage ordering
  depends on serial processing.

### Forbidden Inspection Actions

Merge orchestration is mechanical: run the wrapper, branch on the exit
code, message the Developer. Diagnosing *why* a merge failed is the work
of the Developer who owns `pbi/<pbi-id>`. The general Delegate-mode rule
lives in `../../agents/scrum-master.md` § Scrum Master judgment; these
are its merge-specific prohibitions.

- Never read files under `.scrum/worktrees/<pbi-id>/` — impl source,
  tests, design specs — and never edit them to resolve a conflict.
  `state.merge_failure.paths` is the only inspection artifact SM needs.
- Never search worktree files for conflict markers (`grep -n '<<<<<<'`
  and friends).
- Never run the project toolchain to judge a failure: no `python3 -c`,
  no `source .venv/bin/activate`, no test / lint / build command.
  Relay the wrapper's stderr and the `merge-regression.log` path to the
  Developer instead of reproducing the failure yourself.
- Never run raw `git -C .scrum/worktrees/<pbi-id> …`, read-only
  subcommands included. Worktree git goes through `.scrum/scripts/*.sh`
  wrappers.
- Never route around these by spawning a `scrum-explorer` (or any other
  agent) to inspect the merge for you. Explorers answer bounded
  repository questions; merge diagnosis stays with the assigned
  Developer.

If you reach for any of the above, stop and SendMessage the Developer
with the failure kind and paths verbatim.
