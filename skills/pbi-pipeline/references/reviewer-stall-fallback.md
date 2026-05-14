# Reviewer Stall Fallback

Per-PBI reviewer agents (`codex-design-reviewer`, `codex-impl-reviewer`,
`codex-ut-reviewer`) occasionally stall — the underlying `codex` CLI
hangs and no `.scrum/pbi/<pbi-id>/<stage>/review-r{n}.md` file is
produced even after several minutes. cars_auction_scraping_proto
retrospectives logged this exact pattern across **3 Sprints in a row**
(sprint-4 imp-014, sprint-5 imp-014, sprint-6 imp-015) before a
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
     **identical prompt** from `sub-agent-prompts.md` but with the
     subagent_type swapped:
     ```text
     Agent(subagent_type="Explore",
           prompt=<same codex-<stage>-reviewer prompt verbatim>)
     ```
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
   FAIL / escalate) apply unchanged.

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
