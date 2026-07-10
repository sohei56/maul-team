---
name: scaffold-design-spec
description: Create template stub files for newly enabled catalog entries, including user-facing documentation
disable-model-invocation: false
---

## Inputs

- `docs/design/catalog.md` (doc type reference)
- `docs/design/catalog-config.json` (enabled spec IDs)
- `sprint.json` → id
- `backlog.json` → PBI IDs for related_pbis

## Outputs

- `docs/design/specs/{category}/{id}-{slug}.md` stub files
- YAML frontmatter: catalog_id, created_sprint, last_updated_sprint, related_pbis, frozen: false, revision_history

## Preconditions

- state.json phase: "sprint_planning"
- catalog.md, catalog-config.json, sprint.json, backlog.json exist

## Steps

1. Read catalog-config.json→enabled IDs. Cross-reference catalog.md→get category/name/granularity
2. Each enabled entry without existing file:
   a. Create `docs/design/specs/{category}/{id}-{slug}.md` (auto-create dirs)
   b. YAML frontmatter: catalog_id, created_sprint, last_updated_sprint (same), related_pbis, frozen: false, revision_history (initial entry: sprint, author: "scrum-master", date, summary: "Initial stub created", pbis)
   c. Placeholder sections: Overview, Design Details, Constraints, References
   d. Category `docs/`→doc placeholders: Overview, Usage, API Reference, Examples
   e. Category `technology/`→library-spec placeholders: Library & Version,
      Verified API Surface, Gotchas, Sources (source URL per claim)
3. Skip existing stubs (idempotent)
4. Report: count created, new file paths

### Multi-instance types (D-001, S-022, S-070)

`D-001` (one file per decision), `S-022` (one per external service), and
`S-070` (one per third-party library) are multi-instance. Scaffold the single
name-slug base stub as for any enabled ID; **additional instances are created
on demand by their owning agent** — e.g. `pbi-designer` writes
`technology/S-070-<lib-slug>.md` per library during the Design stage. All files
sharing an enabled ID's prefix satisfy Governance Rules 1–2 (keyed on spec ID,
not exact slug); do not delete extra instances as "non-enabled".

Ref: FR-004

## Exit Criteria

- Every enabled catalog entry has stub file
- All stubs: valid YAML frontmatter with all required fields
- docs/ category→doc-oriented placeholders
- No duplicate stubs

## Handoff (commit before base freeze)

This skill only writes stubs to the working tree. The caller
(`sprint-planning` Step 13) MUST commit `docs/design/` to main before
`spawn-teammates` runs `freeze-sprint-base.sh` — worktrees fork from
committed HEAD, so an uncommitted stub reaches no PBI worktree.
`freeze-sprint-base.sh` refuses while `docs/design/` is dirty.
