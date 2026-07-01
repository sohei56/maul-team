# Design Spec Catalog

This file is the single source of truth for which design specification types
exist. It defines the complete list of recognized document types, their IDs,
and granularity. **Do not create, request, or reference any specification
document that is not listed here.**

Which specs are active for a given project is controlled by
`docs/design/catalog-config.json` (a JSON file with an `enabled` array of spec
IDs). This catalog file itself is read-only in working directories.

## Governance Rules

The following rules are mandatory and enforceable:

1. **Enabled specs require files.** If a spec ID is listed in
   `docs/design/catalog-config.json`'s `enabled` array, a corresponding file
   MUST exist at:
   `docs/design/specs/{category}/{id}-{slug}.md`
   (e.g., `docs/design/specs/system-wide/S-001-system-architecture.md`).

2. **Non-enabled specs prohibit files.** If a spec ID is NOT listed in
   `docs/design/catalog-config.json`'s `enabled` array, no corresponding file
   may exist under `docs/design/specs/`. If a file is found for a non-enabled
   spec, it MUST be deleted or the spec ID MUST be added to the `enabled`
   array first.

3. **Config-first workflow.** When project needs change:
   (1) Update `docs/design/catalog-config.json` to add/remove the spec ID from
   the `enabled` array.
   (2) Then create or remove the corresponding spec files.
   Never create a spec file without an enabled config entry. Never remove
   a config entry without first removing its spec file.

4. **No undocumented specs.** Do not create, request, or reference any
   specification document that is not listed in this catalog. If a new
   spec type is needed, add it to this catalog in `claude-scrum-team` first.

5. **Category directories.** Spec files are organized by category:
   `decision-records/`, `system-wide/`, `data/`, `interface/`, `ui/`,
   `logic/`, `quality/`, `operations/`, `technology/`, `docs/`.

6. **Immediate stub creation.** When a spec ID is added to the `enabled`
   array in `catalog-config.json`, a template stub file MUST be created
   immediately via the `scaffold-design-spec` Skill. The stub includes
   required YAML frontmatter (`catalog_id`, `created_sprint`,
   `related_pbis`, `frozen`, `revision_history`) and placeholder sections.

7. **Catalog is read-only in working directories.** This file is the single
   source of truth managed in `claude-scrum-team`. Do not modify it in
   project working directories. Only `docs/design/catalog-config.json` may be
   edited to control which entries are active.

## How to read this catalog

This catalog lists every recognized design document type. To determine
which specs are active for your project, check `docs/design/catalog-config.json`:

- If a spec ID appears in the `enabled` array, it is active and a
  corresponding file MUST exist under `docs/design/specs/{category}/`.
- If a spec ID does not appear in the `enabled` array, it is inactive.
  No file should exist for it.

## Decision Records

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| D-001 | Architecture Decision Record     | One file per decision                |

## System-Wide

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-001 | System Architecture              | One per project                      |
| S-002 | Application Overview             | One per project                      |
| S-003 | Infrastructure / Deployment      | One per project                      |
| S-004 | Security Architecture            | One per project                      |
| S-005 | Observability / Monitoring       | One per project                      |

## Data

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-010 | Data Model / Entity Design       | One per domain aggregate or logical module |
| S-011 | Database Design                  | One per database                     |
| S-012 | Data Flow / Pipeline             | One per pipeline                     |

## Interface

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-020 | API Specification                | One per domain boundary              |
| S-021 | Event / Message Contract         | One per event channel                |
| S-022 | External Integration             | One per external service             |
| S-023 | WebSocket / Realtime             | One per realtime feature             |

## UI

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-030 | Screen / Page Design             | One per screen                       |
| S-031 | UI Component Design              | One per component group              |
| S-032 | Design System / Style Guide      | One per project                      |
| S-033 | Navigation / Routing             | One per project                      |
| S-034 | UX Flow / User Journey           | One per project                      |

## Logic

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-040 | Business Rule / Domain Logic     | One per bounded context              |
| S-041 | Batch / Scheduled Job            | One per job                          |
| S-042 | Workflow / State Machine         | One per workflow                     |

## Quality

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-050 | Test Strategy                    | One per project                      |
| S-051 | Performance / SLA                | One per project                      |
| S-052 | Error Handling / Logging         | One per project                      |
| S-053 | Accessibility (a11y)             | One per project                      |
| S-054 | Privacy / Data Handling          | One per project                      |

## Operations

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-060 | Migration / Upgrade              | One per migration                    |
| S-061 | Configuration Management         | One per project                      |
| S-062 | Disaster Recovery / Backup       | One per project                      |
| S-063 | Runbook / Ops Playbook           | One per project                      |

## Technology

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| S-070 | Library Specification            | One file per third-party library     |

`S-070` is a multi-instance type (like `D-001`): each significant
third-party library the project depends on gets its own
`docs/design/specs/technology/S-070-<lib-slug>.md`. It is authored by
`pbi-designer` during the Design stage and holds **only web-search-verified**
facts about the library (version, the exact API surface the project uses with
signatures / parameter / return / error semantics, gotchas to avoid) with a
**source URL for every claim**. Its purpose is to prevent implementation
defects caused by library-API misuse. See `agents/pbi-designer.md` §
Mandatory library selection & verified-spec research.

## Documentation

| ID    | Spec Name                        | Granularity                          |
|-------|----------------------------------|--------------------------------------|
| D-011 | README / Feature Documentation   | One per feature or section           |
| D-012 | API Reference                    | One per API boundary                 |
| D-013 | Usage Guide                      | One per feature or workflow          |
| D-014 | CLI Reference                    | One per CLI tool                     |
| D-015 | Configuration Reference          | One per project                      |
