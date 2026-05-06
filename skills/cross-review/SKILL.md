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

- state.json → phase: pbi_pipeline_active | review
- backlog.json → all Sprint PBIs with implementation complete
- requirements.md + design docs per PBI
- agents/code-reviewer.md, agents/security-reviewer.md
- Per-PBI pipeline final reviews (read for context, NOT re-evaluated):
  - `.scrum/pbi/<pbi-id>/impl/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/ut/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/metrics/coverage-r{last}.json`

## Outputs

- `.scrum/reviews/<pbi-id>-review.md` (per PBI)
- pbi/<id>/state.json → phase: complete → review_complete
  (backlog.json items[].status auto-projected to review → done by
  `update-pbi-state.sh`; never write `backlog.json.status` directly)
- backlog.json → items[].review_doc_path (this field is hand-written; status is not)
- state.json → phase: review
- sprint.json → status: "cross_review"

## Preconditions

- state.json phase: "pbi_pipeline_active" or "review"
- backlog.json has PBIs with implementation complete
- requirements.md exists
- App builds + starts (verified during implementation; if uncertain→re-verify)

## Steps

1. state.json → phase: "review", sprint.json → status: "cross_review"
2. All Sprint PBIs already at `pbi/<id>/state.json.phase = complete` from
   pbi-pipeline; backlog.status is therefore already `review` (auto-derived).
   No direct backlog.status write here — `update-backlog-status.sh` rejects
   post-pipeline statuses by design.
3. **Pre-review build verification**: Start app→all tests pass. Fail→`TaskGet` Developer status→terminated? re-spawn (Teammate Liveness Protocol)→then relay fix request. Do NOT review non-building code
4. Collect review inputs per PBI: design_doc_paths, source paths, requirements.md path
5. **Spawn 2 sub-agents per PBI in parallel (Agent tool)**:
   - `codex-code-reviewer` (fallback `code-reviewer` when `codex` CLI unavailable; log warning) → design doc paths + source paths + requirements.md. Do NOT pass PBI descriptions, dev communications, .scrum/ state
   - `security-reviewer` → source paths + requirements.md
6. Collect results from both
7. **Doc-implementation consistency check**: Compare design docs + user-facing docs vs actual code. Mismatch→send Developer to update docs (not code)
8. **Handle FAIL**: `TaskGet` Developer status→terminated? re-spawn (Teammate Liveness Protocol). Relay findings to Developer→fix→re-spawn failing reviewer(s)→repeat until both PASS
9. Write `.scrum/reviews/<pbi-id>-review.md` (combined code + security review)
10. Both PASS → advance pipeline phase to `review_complete`
    (backlog.status auto-projects to `done`):
    ```bash
    .scrum/scripts/update-pbi-state.sh "$PBI_ID" phase review_complete
    ```
11. Set items[].review_doc_path

Ref: FR-009

## Exit Criteria

- App builds + tests pass (verified before review)
- All Sprint PBIs reviewed by code-reviewer + security-reviewer
- Doc-implementation consistency verified
- `.scrum/reviews/<pbi-id>-review.md` exists per PBI
- Passing PBIs: status: "done"
- review_doc_path set
- Unresolvable issues→logged as new PBIs
- state.json phase: "review"
