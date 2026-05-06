---
name: cross-review
description: >
  Independent code review — Scrum Master spawns code-reviewer and
  security-reviewer sub-agents for unbiased, design-driven review.
disable-model-invocation: false
---

## Role (post pbi-pipeline introduction)

Sprint-end cross-cutting quality gate. The PBI Pipeline already runs
per-PBI impl + UT reviews via codex-impl-reviewer / codex-ut-reviewer.
This `cross-review` complements that by:

- Catching cross-PBI integration issues
- Independent security perspective (security-reviewer)
- Final code-reviewer pass with full Sprint context

Do NOT duplicate per-PBI quality work; assume per-PBI Pass criteria
already satisfied (see `.scrum/pbi/<pbi-id>/impl/review-r{last}.md` and
`ut/review-r{last}.md` for prior context).

## Inputs

- `state.json` (overall project phase: `pbi_pipeline_active` or `review`)
- backlog.json → all Sprint PBIs at `status ∈ {awaiting_cross_review, escalated}`
- requirements.md + design docs per PBI
- agents/code-reviewer.md, agents/security-reviewer.md
- Per-PBI pipeline final reviews (read for context, NOT re-evaluated):
  - `.scrum/pbi/<pbi-id>/impl/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/ut/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/metrics/coverage-r{last}.json`

## Outputs

- `.scrum/reviews/<pbi-id>-review.md` (per PBI)
- backlog.json `items[].status` transitions:
  - At step 1: `awaiting_cross_review → cross_review` for each Sprint PBI
  - On both reviewers PASS: `cross_review → done`
  - On reviewer FAIL: `cross_review → in_progress_impl` (Developer fixes
    on top of merged code, re-runs UT, re-marks ready-to-merge, SM
    re-merges, status returns to `awaiting_cross_review`, then this
    skill re-runs for that PBI)
- backlog.json → items[].review_doc_path (hand-written; status writes
  go through `update-backlog-status.sh`)
- `state.json` (overall project phase: `review`)
- `sprint.json.status: "cross_review"`

## Preconditions

- Every Sprint PBI is at backlog `status ∈ {awaiting_cross_review,
  escalated}`. PBIs at `in_progress_merge` or any other
  `in_progress_*` value must be driven to one of those terminal
  values (via `pbi-merge` or `pbi-escalation-handler`) before this
  skill is invoked.
- Review target: the merged main HEAD (only the PBIs at
  `awaiting_cross_review`; `escalated` PBIs are not reviewed here).
- App builds + starts (verified during implementation; if uncertain→re-verify)

## Steps

1. `state.json` → overall phase `"review"`; `sprint.json.status →
   "cross_review"`. For every Sprint PBI at `status =
   awaiting_cross_review`, transition to `cross_review`:
   ```bash
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" cross_review
   ```
2. Sanity check: every Sprint PBI is now at `status ∈ {cross_review,
   escalated}`. (No PBIs at `awaiting_cross_review` or `in_progress_*`.)
3. **Pre-review build verification**: Start app→all tests pass. Fail→`TaskGet` Developer status→terminated? re-spawn (Teammate Liveness Protocol)→then relay fix request. Do NOT review non-building code
4. Collect review inputs per PBI: design_doc_paths, source paths, requirements.md path
5. **Spawn 2 sub-agents per PBI in parallel (Agent tool)**:
   - `codex-code-reviewer` (fallback `code-reviewer` when `codex` CLI unavailable; log warning) → design doc paths + source paths + requirements.md. Do NOT pass PBI descriptions, dev communications, .scrum/ state
   - `security-reviewer` → source paths + requirements.md
6. Collect results from both
7. **Doc-implementation consistency check**: Compare design docs + user-facing docs vs actual code. Mismatch→send Developer to update docs (not code)
8. **Handle FAIL**: For each PBI where any reviewer returns FAIL:
   - `TaskGet` Developer status → terminated? re-spawn (Teammate Liveness Protocol)
   - Revert that PBI: `update-backlog-status.sh "$PBI_ID" in_progress_impl`
     (Developer fixes on top of merged code, re-runs through PBI Review →
     UT Run → ready-to-merge handoff. SM re-merges; PBI returns to
     `awaiting_cross_review`. Re-trigger step 1 for that single PBI.)
   - Repeat until both reviewers PASS for every Sprint PBI
9. Write `.scrum/reviews/<pbi-id>-review.md` (combined code + security review)
10. Both PASS → mark PBI as cross-review-complete:
    ```bash
    .scrum/scripts/update-backlog-status.sh "$PBI_ID" done
    ```
11. Set `items[].review_doc_path`

Ref: FR-009

## Exit Criteria

- App builds + tests pass (verified before review)
- All Sprint PBIs reviewed by code-reviewer + security-reviewer
- Doc-implementation consistency verified
- `.scrum/reviews/<pbi-id>-review.md` exists per PBI
- Passing PBIs: `status: done`
- `review_doc_path` set
- Unresolvable issues→logged as new PBIs
- `state.json` overall phase: `review`
