# Design Stage Reference

Per-Round flow for the design stage (max 5 Rounds). Backlog status
during this stage is `in_progress_design`.

## Round n procedure

1. **Prepare**
   - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_round "$n" design_status pending`
   - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" start —`

2. **Step 1: Spawn pbi-designer** (single Agent call)
   - Build prompt from `sub-agent-prompts.md` § pbi-designer
   - Wait for completion
   - Parse JSON envelope from output. If status=error → escalate.
   - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_status in_review`

3. **Step 2: Spawn codex-design-reviewer** (single Agent call)
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
   - Build prompt from `sub-agent-prompts.md` § codex-design-reviewer
   - Apply `reviewer-stall-fallback.md` (2-min stall detect →
     single Explore-agent retry → escalate as `reviewer_unavailable`
     if both fail)
   - Read .scrum/pbi/<pbi-id>/design/review-r{n}.md → parse Verdict.
   - **Snapshot-pin verification.** The review file MUST begin with
     `Reviewed-Design-Hash: <DESIGN_HASH>`. If the header is missing
     or mismatched, OR the reviewer's JSON envelope returns
     `status=error` with `summary` starting `stale_snapshot:` —
     re-capture `DESIGN_HASH` and respawn the reviewer ONCE with the
     refreshed pin slot. If the second attempt also fails
     verification, escalate with `escalation_reason=stale_review_snapshot`:
     ```bash
     .scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason stale_review_snapshot
     .scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
     .scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "escalate → stale_review_snapshot"
     notify_sm_escalation "$PBI_ID" stale_review_snapshot
     ```

4. **Step 3: Termination gate** (see termination-gates.md)
   - **Success**: design-reviewer verdict == PASS
     - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_status pass impl_round 0`
     - `.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl`
     - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "success → in_progress_impl"`
     - Return to caller (impl stage begins)
   - **Stagnation / Divergence / Hard cap**: escalate
     - `.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason "<reason>"`
     - `.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated`
     - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "escalate → <reason>"`
     - Notify SM (see `escalation-notify` snippet below)
   - **Other FAIL**: review-r{n}.md becomes input to Round n+1
     - `.scrum/scripts/append-pbi-log.sh "$PBI_ID" design "$n" gate "fail → round $((n+1))"`
     - Increment n, recurse.

## escalation-notify snippet

```bash
notify_sm_escalation() {
  local pbi_id="$1" reason="$2"
  # Use the Agent Teams notification mechanism. Implementation in
  # current Developer agent uses TaskUpdate or message-passing —
  # invoke whichever convention applies.
  echo "[$pbi_id] ESCALATED reason=$reason last_review=$(latest_review_path "$pbi_id")"
}
```

## Notes

- The design-stage round counter is independent from the impl-stage
  counter (`impl_round`).
- pbi-designer may request catalog scaffolding from SM by raising
  status=error with next_actions[]=["scaffold catalog spec X"]; pause
  PBI until SM completes.
