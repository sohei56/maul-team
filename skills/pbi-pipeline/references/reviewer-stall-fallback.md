# Reviewer Stall Fallback

Per-PBI reviewer agents (`codex-design-reviewer`, `codex-impl-reviewer`,
`codex-ut-reviewer`) occasionally stall — the underlying `codex` CLI
hangs and no `.scrum/pbi/<pbi-id>/<stage>/review-r{n}.md` file is
produced even after several minutes. Target-project retrospectives
logged this exact pattern across **3 Sprints in a row** before a
fallback protocol was made explicit. Without a documented fallback,
the Developer waits indefinitely, the SM cannot tell stall from slow
review, and `completion-gate.sh` keeps blocking session exit.

## Protocol

For every codex-\* reviewer spawn (design / impl / ut stages):

1. **Spawn** as normal via `Agent(subagent_type="codex-<stage>-reviewer", prompt=...)`.

2. **Wait barrier — bounded.** Poll for the target
   `review-r{n}.md` file. The reviewer is considered alive while either:
   - The Task is `running` AND total elapsed time < 5 minutes, OR
   - `review-r{n}.md` exists and has mtime ≥ the spawn timestamp.

3. **Stall detection.** Treat the reviewer as stalled when **both**:
   - 2 minutes elapsed since spawn, AND
   - `review-r{n}.md` does NOT yet exist (or exists with stale mtime).

   `TaskGet` showing `status=running` for 2+ minutes with no output
   file is the canonical signal — the underlying tool is hung.

4. **Fallback action — single retry through a different surface.**
   - `TaskStop` the stalled `codex-<stage>-reviewer` task.
   - Re-spawn the same review with the generic `Explore` agent (or
     `general-purpose` if `Explore` is unavailable), passing the
     **identical prompt** from `sub-agent-prompts.md` (same pin
     slots: `{review_sha}`, `{design_hash}`, `{worktree_path}` where
     applicable) but with the subagent_type swapped:
     ```text
     Agent(subagent_type="Explore",
           prompt=<same codex-<stage>-reviewer prompt verbatim>)
     ```
   - The Explore-agent obeys the same FIRST-action pin verification
     described in the codex agent definitions and emits the same
     `stale_snapshot:` error envelope on mismatch.
   - The generic agent runs the same instructions under a Claude
     backend and reliably produces the review file. Output target is
     unchanged (`review-r{n}.md`).
   - Log the fallback for diagnostic continuity:
     ```bash
     .scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" \
       fallback "codex stall → Explore reviewer"
     ```

5. **Verdict parsing.** Identical to the codex path — read
   `review-r{n}.md`, parse the Verdict. Termination gates (PASS /
   FAIL / escalate) apply unchanged. The conductor applies the same
   post-hoc header verification (`Reviewed-Head:` /
   `Reviewed-Design-Hash:`) to fallback output as it does to native
   codex output; mismatch / `stale_snapshot:` envelope follows the
   single-respawn-then-escalate-`stale_review_snapshot` protocol in
   `design-stage.md` / `impl-ut-stage.md`.

## Bounded waiting only

All waiting on a codex review MUST stay bounded. There are **two
independent** timeout layers — do not conflate them:

- **Conductor stall trigger (2 min, this document).** The conductor
  declares the reviewer stalled at 2 minutes with no output file and
  switches to the Explore-agent retry (step 3–4 above). This is the
  primary bound and normally fires FIRST.
- **Helper hard timeout (`CODEX_TIMEOUT_SECS`, default 300 s, inside
  `codex-invoke.sh`).** The reviewer sub-agent runs codex through the
  helper, which fail-fasts a hung `codex exec` into its own Claude
  fallback at 300 s. This is a deeper backstop for the case where the
  sub-agent itself keeps waiting; the conductor's 2-min trigger
  usually preempts it (and a `TaskStop` discards the in-flight codex).

Because the conductor trigger (2 min) is shorter than the helper
timeout (300 s), the helper timeout is rarely reached — it exists as a
last-resort backstop, not the primary bound. Agents must NOT improvise
an unbounded busy-wait loop such as `until [ -f review-r{n}.md ]; do
:; done` (no `sleep`): a tight spin pegs a CPU core and, because
neither layer can interrupt a spin inside the conductor itself, hangs
the session forever. This is the documented mitigation for a real
stall incident — rely on the 2-min stall trigger + single-retry
protocol above (with the 300 s helper timeout as backstop), never a
hand-rolled spin loop.

## Notes

- The fallback is a **single retry**, not a polling loop. If the
  Explore-based reviewer also fails to produce a verdict file within
  5 minutes, escalate via `pbi-escalation-handler` with
  `escalation_reason = "reviewer_unavailable"`. Do not chain further
  retries — repeated stalls indicate an environment problem, not a
  prompt problem.
- Do NOT mix codex output and Explore output in the same
  `review-r{n}.md`. The fallback overwrites the file; the codex
  partial output (if any) is discarded.
- The Sprint-end aspect reviewers in `cross-review` are **not**
  covered by this protocol — they are not codex-backed. See
  `skills/cross-review/SKILL.md` Step 8 "Reviewer wait barrier" for
  the analogous policy on that side.
