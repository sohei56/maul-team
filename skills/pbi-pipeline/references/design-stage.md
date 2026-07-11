# Design Stage Reference

Per-Round flow for the design stage (max 5 Rounds). Backlog status
during this stage is `in_progress_design`.

## kind=docs PBI: stage entirely skipped

If `backlog.json items[].kind == "docs"`, this stage does **not** run.
The conductor sets `design_status = "skipped"` and `design_round = 0`
at Init, then transitions backlog status directly to
`in_progress_impl` (skipping `in_progress_design` entirely). No
`pbi-designer` or `codex-design-reviewer` is spawned, no
`.scrum/pbi/$PBI_ID/design/design.md` is created, and no
`design-r{n}.md` review file is produced. See `pbi-pipeline/SKILL.md`
§ Stages and `impl-ut-stage.md` for the docs flow.

Rationale: doc-only PBIs (modifications confined to `*.md` files
under any directory — `docs/**`, `skills/**`, `agents/**`,
`CLAUDE.md`, `README.md`) edit existing prose. Design documents about
documents are noise; the parent PBI's per-PBI Integrity review digest
(`.scrum/reviews/<parent-pbi-id>-review.md`) or the docs-consistency
follow-up payload already constitute the design input. The implementer
reads those directly.

## Round n procedure (kind=code only)

1. **Prepare**
   - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_round "$n" design_status pending`
   - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" start —`

2. **Step 1: Spawn pbi-designer** (single Agent call, synchronous —
   `run_in_background: false`)
   - Snapshot main-checkout status first (see
     `worktree-containment.md` § Procedure, `MAIN_SNAP_BEFORE`)
   - Build prompt from `sub-agent-prompts.md` § pbi-designer, filling
     `{worktree_path}` with the conductor's worktree absolute path
     (`$(pwd)`)
   - The designer performs **mandatory library selection web search**
     and emits the design.md `Library Selection` section plus any
     `docs/design/specs/technology/S-070-<lib>.md` verified specs (see
     `../../../agents/pbi-designer.md` § Mandatory library selection &
     verified-spec research). A pure-stdlib PBI satisfies this with the
     explicit stdlib-only statement. If the designer reports a
     WebSearch harness incident (status=error), escalate — do not let
     it fabricate specs.
   - Wait for completion
   - **Containment check**: compare against `MAIN_SNAP_BEFORE`; a
     leaked write into the main checkout (e.g. a catalog spec at
     `<main>/docs/design/specs/...`) must be relocated into the
     worktree before proceeding — full procedure in
     `worktree-containment.md`.
   - Parse JSON envelope from output. If status=error → escalate.
   - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_status in_review`

3. **Step 2: Spawn codex-design-reviewer** (single Agent call,
   synchronous — `run_in_background: false`)
   - Capture the design-doc content hash before spawning so the
     reviewer can verify it is reading the same bytes the conductor
     intends to review (design.md lives under untracked `.scrum/`,
     so no git SHA applies — only the content hash):
     ```bash
     DESIGN_HASH="$(shasum -a 256 .scrum/pbi/$PBI_ID/design/design.md \
       | awk '{print $1}')"
     ```
     `DESIGN_HASH` is passed into the prompt as the pin slot (see
     `sub-agent-prompts.md` § codex-design-reviewer).
   - **Codex preflight** (see `sub-agent-prompts.md` § Conductor
     codex preflight). Choose the spawn model for this single call:
     ```bash
     source scripts/lib/codex-invoke.sh
     codex_is_available && SPAWN_MODEL="" || SPAWN_MODEL="opus"
     ```
     Codex present → `Agent(subagent_type="codex-design-reviewer", prompt=<...>)`.
     Codex absent → `Agent(subagent_type="codex-design-reviewer", model="opus", prompt=<...>)`.
   - Build prompt from `sub-agent-prompts.md` § codex-design-reviewer
   - Apply `reviewer-stall-fallback.md` (post-return persistence check →
     single general-purpose-agent retry → escalate as `reviewer_unavailable`
     if both fail)
   - If the reviewer Task **completes** without writing
     `review-r{n}.md`, apply `reviewer-stall-fallback.md`
     § Completed-but-unpersisted verdict in the same turn: persist
     the returned verdict verbatim if complete (header + Verdict +
     envelope), else single general-purpose retry — never fabricate,
     never idle waiting for the file.
   - Read .scrum/pbi/<pbi-id>/design/review-r{n}.md → parse Verdict.
   - **Snapshot-pin verification.** The review file MUST begin with
     `Reviewed-Design-Hash: <DESIGN_HASH>`. If the header is missing
     or mismatched, OR the reviewer's JSON envelope returns
     `status=error` with `summary` starting `stale_snapshot:` —
     re-capture `DESIGN_HASH` and respawn the reviewer ONCE with the
     refreshed pin slot. If the second attempt also fails
     verification, run the canonical escalation transition
     (`termination-gates.md` § Status transition on escalation) with
     `<reason>=stale_review_snapshot` and `<stage>=design`.

4. **Step 3: Termination gate** (see termination-gates.md)
   - **Success**: design-reviewer verdict == PASS
     - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_status pass impl_round 0`
     - `.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl`
     - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "success → in_progress_impl"`
     - Return to caller (impl stage begins)
   - **Stagnation / Divergence / Hard cap**: run the canonical
     escalation transition (`termination-gates.md` § Status transition
     on escalation) with `<reason>` = the gate outcome and
     `<stage>=design`. It performs the two state writes, the
     `pipeline.log` line, and `notify_sm_escalation` (defined in the
     `escalation-notify` snippet below).
   - **Other FAIL**: review-r{n}.md becomes input to Round n+1
     - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "fail → round $((n+1))"`
     - Increment n, recurse.

## escalation-notify snippet

```bash
notify_sm_escalation() {
  local pbi_id="$1" reason="$2" last_review
  # Newest review file across the design/impl/ut stages, by mtime.
  # `ls -t | head -1` is fine in this doc snippet: review paths are
  # framework-generated and contain no spaces or newlines.
  last_review="$(ls -t \
    ".scrum/pbi/$pbi_id/design/"review-r*.md \
    ".scrum/pbi/$pbi_id/impl/"review-r*.md \
    ".scrum/pbi/$pbi_id/ut/"review-r*.md \
    2>/dev/null | head -n 1)"
  [ -n "$last_review" ] || last_review="none"
  # Use the Agent Teams notification mechanism. Implementation in
  # current Developer agent uses TaskUpdate or message-passing —
  # invoke whichever convention applies.
  echo "[$pbi_id] ESCALATED reason=$reason last_review=$last_review"
}
```

## Notes

- The design-stage round counter is independent from the impl-stage
  counter (`impl_round`).
- pbi-designer may request catalog scaffolding from SM by raising
  status=error with next_actions[]=["scaffold catalog spec X"]; pause
  PBI until SM completes.
