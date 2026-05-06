---
name: sprint-planning
description: Sprint Planning ceremony — select PBIs, assign developers, create Sprint
disable-model-invocation: false
---

## Inputs

- `state.json` → phase: backlog_created | retrospective
- `backlog.json` → PBIs with status: refined

## Outputs

- `sprint.json`: id, goal, type: development, status: planning, pbi_ids, developer_count
- `backlog.json` → items[].sprint_id, implementer_id, reviewer_id assigned
- Oversized PBIs split into children (parent_pbi_id set)
- `state.json` → phase: sprint_planning

## Preconditions

- state.json phase: "backlog_created" or "retrospective"
- backlog.json has ≥1 refined PBI
- No active Sprint in progress

## Steps

1. **Uncommitted file check (mandatory)**: Run `git status`→uncommitted changes exist→warn user with file list→user must choose: commit now, stash, or proceed anyway→resolve before continuing
2. **Transition state**: state.json → phase: "sprint_planning" (TUI reflects immediately)
3. Propose Sprint Goal→user approval before proceeding
4. Select refined PBIs. Avoid dependent PBIs in same Sprint (FR-008)
5. **Evaluate + split oversized PBIs**: Too large→create child PBIs (status: "refined", parent_pbi_id set, split acceptance_criteria, copy design_doc_paths/ux_change)→remove parent from Sprint→replace with children→user confirmation
6. developer_count = min(selected PBI count, 6). **1 Developer = 1 PBI (hard constraint).** >6 PBIs→select 6, defer rest
7. Assign implementers: format `dev-001-s{N}`, `dev-002-s{N}` (zero-pad mandatory, -s{N} suffix mandatory, no short forms)
8. Assign reviewers: round-robin (no self-review). Single-PBI Sprint→reviewer_id: "scrum-master"
9. Create sprint.json

    > **TODO(scrum-state-tools):** Needs `init-sprint.sh` wrapper —
    > existing wrappers require `.scrum/sprint.json` to exist and raw
    > Write/Edit is blocked. See `docs/MIGRATION-scrum-state-tools.md`.

10. Update backlog.json: sprint_id, implementer_id, reviewer_id

    > **TODO(scrum-state-tools):** Needs `set-backlog-item-field.sh`
    > (or per-field wrappers) for `items[].{sprint_id,implementer_id,reviewer_id}`.
    > See `docs/MIGRATION-scrum-state-tools.md`.

11. **Catalog Target Assignment** (PBI Pipeline parallel-safety):

    For each PBI in the sprint:
    1. Read PBI description + requirements to identify catalog spec
       paths it will touch (entries enabled in catalog-config.json).
    2. Record in backlog.json items[].catalog_targets[]:

       > **TODO(scrum-state-tools):** Blocked at runtime — needs (a)
       > `catalog_targets` added to `backlog.schema.json` (currently
       > rejected by `additionalProperties: false`); (b) a wrapper such
       > as `set-backlog-item-field.sh`. See
       > `docs/MIGRATION-scrum-state-tools.md`.

       ```bash
       jq --arg id "$PBI_ID" --argjson targets "$TARGETS_JSON" \
         '(.items[] | select(.id == $id)).catalog_targets = $targets' \
         .scrum/backlog.json > .scrum/backlog.json.tmp \
         && mv .scrum/backlog.json.tmp .scrum/backlog.json
       ```
    3. **Conflict check**: For PBIs with overlapping catalog_targets in
       this sprint, ensure they are NOT assigned to different
       developers in parallel. Either sequence them on one developer,
       or split the PBI to remove overlap.
    4. If overlap unavoidable → note in sprint.json that runtime flock
       will arbitrate (Layer 2 of catalog-contention defense).

> **Note (worktree governance).** Per-PBI worktrees give physical
> isolation, so two PBIs touching the same source file no longer
> corrupt each other at write time. Conflicts surface during
> `pbi-merge` and the assigned Developer rebases. Pre-separation is
> still required for catalog files (see `catalog-contention.md`).
12. **Present Sprint summary + options**:
    - 1. Start Sprint
    - 2. Adjust Sprint Goal
    - 3. Change PBI selection
    - 4. Re-assign developers
    - 5. View backlog
    - 6. Other
    → Wait for user selection
13. **On "Start Sprint"**: Enable catalog-config.json entries→run scaffold-design-spec→spawn-teammates

Ref: FR-004, FR-005, FR-006, FR-007, FR-008

## Exit Criteria

- sprint.json exists (status: planning, all fields set)
- All PBIs: implementer_id + reviewer_id assigned
- 1 Developer = 1 PBI (1:1)
- No self-review
- state.json phase: sprint_planning
