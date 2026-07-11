# Reviewer Stall Fallback

Per-PBI reviewer agents (`codex-design-reviewer`, `codex-impl-reviewer`,
`codex-ut-reviewer`) occasionally stall — the underlying `codex` CLI
hangs and no `.scrum/pbi/<pbi-id>/<stage>/review-r{n}.md` file is
produced. Target-project retrospectives logged this exact pattern
across **3 Sprints in a row** before a fallback protocol was made
explicit. Without a documented fallback, the Developer waits
indefinitely, the SM cannot tell stall from slow review, and
`completion-gate.sh` keeps blocking session exit.

Every reviewer spawn is **synchronous** (`run_in_background: false`;
see `../../pbi-pipeline/SKILL.md` § Sub-agents spawned). The
conductor is blocked inside the Agent call until it returns, so there
is no in-flight observation point: all stall handling happens **after
the call returns**. The only in-flight bound is the codex helper's
`CODEX_TIMEOUT_SECS` backstop inside the reviewer itself (timeout
contract: see `codex-design-reviewer` § Model selection).

## Protocol

For every codex-\* reviewer spawn (design / impl / ut stages):

1. **Record the spawn timestamp, then spawn synchronously** via
   `Agent(subagent_type="codex-<stage>-reviewer",
   run_in_background: false, prompt=...)`. The call blocks until the
   reviewer finishes or the spawn itself errors.

2. **Post-return check — the single detection point.** When the
   synchronous call returns (normally or with an error), check the
   target `review-r{n}.md`:

   - exists AND has mtime ≥ the spawn timestamp → fresh review file;
     go to step 5.
   - missing, or mtime predates the spawn timestamp → no usable
     file; go to step 3.

   There is no polling and no mid-flight cancellation in this model:
   a conductor blocked inside a synchronous Agent call cannot poll
   for the file, measure elapsed time, or stop the reviewer while it
   runs. (This is why the earlier async mechanics — `TaskGet` status
   polling, a 2-minute elapsed-time stall trigger, `TaskStop` on the
   stalled task — no longer exist in this protocol: they require a
   background task handle that the synchronous model does not have.)
   An in-flight codex hang is instead cut short inside the reviewer
   by the helper's `CODEX_TIMEOUT_SECS` backstop.

3. **Classify the no-file outcome.** With the call returned and no
   fresh review file, exactly one of two branches applies:

   - The call returned **normally** and the reviewer's final message
     is a complete verdict (pin headers + Verdict line + JSON
     envelope) → this is a **completed-but-unpersisted verdict**;
     persist it per § Completed-but-unpersisted verdict below. Do
     NOT retry.
   - Anything else — the call errored, the reviewer hit its turn
     budget, or the returned message lacks any required element →
     treat as a **stall** and run the fallback (step 4).

4. **Fallback action — single retry through a different surface.**
   - Re-spawn the same review with the `general-purpose` agent
     (synchronously, like every spawn in this pipeline), passing the
     **identical prompt** from `sub-agent-prompts.md`
     (same pin slots: `{review_sha}`, `{design_hash}`,
     `{worktree_path}` where applicable) but with the subagent_type
     swapped:
     ```text
     Agent(subagent_type="general-purpose",
           run_in_background: false,
           prompt=<same codex-<stage>-reviewer prompt verbatim>)
     ```
     Do NOT use the `Explore` agent here: Explore is read-only (no
     `Write` tool) and cannot persist `review-r{n}.md` — a target
     project's fallback failed exactly this way and burned a second
     retry discovering it. The fallback reviewer must be able to
     write the review file.
   - The fallback agent obeys the same FIRST-action pin verification
     described in the codex agent definitions and emits the same
     `stale_snapshot:` error envelope on mismatch.
   - The generic agent runs the same instructions under a Claude
     backend and reliably produces the review file. Output target is
     unchanged (`review-r{n}.md`).
   - When the fallback call returns, apply the same post-return
     check (step 2) and classification (step 3) to its output.
   - Log the fallback for diagnostic continuity:
     ```bash
     .scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" \
       fallback "codex stall → general-purpose reviewer"
     ```

5. **Verdict parsing.** Identical to the codex path — read
   `review-r{n}.md`, parse the Verdict. Termination gates (PASS /
   FAIL / escalate) apply unchanged. The conductor applies the same
   post-hoc header verification (`Reviewed-Head:` /
   `Reviewed-Design-Hash:`) to fallback output as it does to native
   codex output; mismatch / `stale_snapshot:` envelope follows the
   single-respawn-then-escalate-`stale_review_snapshot` protocol in
   `design-stage.md` / `impl-ut-stage.md`.

## Completed-but-unpersisted verdict

A reviewer call can also **return normally yet leave no
`review-r{n}.md`** — the reviewer returned its full verdict in its
final message and deferred persistence to the conductor. (Historical
cause: a "Read-only" ambiguity in the codex agent definitions; the
definitions now mandate the write, but this branch stays defined
defensively.) This is NOT a stall — no extra waiting is involved;
resolve it in the same turn the synchronous call returns (Protocol
step 3).

When the call returned normally AND `review-r{n}.md` is absent (or
its mtime predates the spawn timestamp):

1. **Inspect the reviewer's returned final message.** It is usable
   only if ALL of the following are present:
   - the pin header lines (`Reviewed-Head:` + `Reviewed-Design-Hash:`;
     design stage: `Reviewed-Design-Hash:` only; kind=docs:
     `Reviewed-Design-Hash: -`),
   - a `**Verdict: PASS | FAIL**` line,
   - the JSON envelope.
2. **Complete → the conductor persists it.** Write the returned
   message content **verbatim** to `review-r{n}.md` — copy; do not
   summarize, reformat, re-order findings, or reconstruct any part.
   Log the handoff for diagnostic continuity:

   ```bash
   .scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" \
     fallback "reviewer returned verdict unpersisted → persisted_by=conductor"
   ```

3. **Incomplete → treat exactly as a stall.** Any missing element
   (header, verdict, envelope) → do NOT persist a partial file and do
   NOT fabricate the missing part; run the single general-purpose
   retry (Protocol step 4). Fabricated pin headers defeat the
   snapshot-pin contract — the headers are evidence that the reviewer
   reviewed the pinned SHA, and only the reviewer may originate them.
4. **Then gate as normal.** Verdict parsing and post-hoc header
   verification (Protocol step 5) apply to the conductor-persisted
   file unchanged.

Never idle in this state: a returned reviewer call with no review
file is always resolved in the same turn, by either step 2
(persist) or step 3 (retry). Waiting for "someone" to write the
file is the historical failure mode this section eliminates.

## Bounded waiting only

All waiting on a codex review is bounded by construction: the
conductor waits inside the synchronous Agent call itself, and the
reviewer's own codex invocation is bounded by the helper's
`CODEX_TIMEOUT_SECS` hard timeout, which fail-fasts a hung
`codex exec` into the reviewer's Claude fallback (timeout contract:
see `codex-design-reviewer` § Model selection). The conductor adds
no timer of its own — its stall detection is a one-shot post-return
check (Protocol step 2), never a wait loop.

Agents must NOT improvise an unbounded busy-wait loop such as `until
[ -f review-r{n}.md ]; do :; done` (no `sleep`): a tight spin pegs a
CPU core and, because no outer layer can interrupt a spin inside the
conductor itself, hangs the session forever. This is the documented
mitigation for a real stall incident — rely on the synchronous call
+ post-return check + single-retry protocol above (with the helper
timeout as the in-flight backstop), never a hand-rolled spin loop.

## Notes

- The fallback is a **single retry**, not a loop. If the fallback
  call also returns without a fresh, complete verdict file (same
  post-return check, same completed-but-unpersisted branch), escalate
  via `pbi-escalation-handler` with
  `escalation_reason = "reviewer_unavailable"`. Do not chain further
  retries — repeated stalls indicate an environment problem, not a
  prompt problem.
- Do NOT mix codex output and fallback output in the same
  `review-r{n}.md`. The fallback overwrites the file; the codex
  partial output (if any) is discarded.
- The per-PBI Integrity-stage aspect reviewers (`integrity-stage.md`)
  are **not** covered by this protocol — they are Claude-backed, not
  codex-backed, and message-based (no review file to stall on). See
  `integrity-stage.md` § Step I-3 for their bounded-wait + single-retry
  handling.
