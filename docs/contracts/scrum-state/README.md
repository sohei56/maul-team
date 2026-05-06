# `.scrum/` Sprint State Schemas (SSOT)

Each schema corresponds to one file under `.scrum/` and is the single source of truth for its on-disk shape today. Both the validated wrapper scripts (`.scrum/scripts/*.sh` in deployed projects; `scripts/scrum/*.sh` in this framework's source tree) and readers (dashboard, hooks) MUST validate against these schemas.

| File                                | Schema                                | Write script (Phase B)                                |
|-------------------------------------|---------------------------------------|-------------------------------------------------------|
| `.scrum/state.json`                 | `state.schema.json`                   | `.scrum/scripts/update-state-phase.sh`                |
| `.scrum/sprint.json`                | `sprint.schema.json`                  | `.scrum/scripts/update-sprint-status.sh`, `set-sprint-developer.sh` |
| `.scrum/backlog.json`               | `backlog.schema.json`                 | `.scrum/scripts/update-backlog-status.sh`, `set-backlog-item-field.sh`, `add-backlog-item.sh` |
| `.scrum/communications.json`        | `communications.schema.json`          | `.scrum/scripts/append-communication.sh`              |
| `.scrum/dashboard.json`             | `dashboard.schema.json`               | `.scrum/scripts/append-dashboard-event.sh`            |
| `.scrum/pbi/<id>/state.json`        | `pbi-state.schema.json`               | `.scrum/scripts/update-pbi-state.sh`                  |

## Design choices

- **Top-level `additionalProperties: true`** — top-level objects routinely grow (`max_events`, `max_messages`, `pbi_pipelines`, etc.). Permissive at the root catches drift via item-level strictness without requiring lockstep schema bumps for new top-level config.
- **Item-level `additionalProperties: false`** — array items (PBIs, developers, messages, events) are where typos cause silent dashboard breakage. Strict here.
- **No `schema_version` field** — YAGNI. Existing files don't carry one. Add if/when an incompatible migration is actually needed.
- **Mirror today's shape exactly** — every field name in the fixtures and writers is allowed; no aspirational renames.

## Out of scope (covered elsewhere)

- PBI sub-agent envelopes — see `docs/contracts/pbi-pipeline-envelope.schema.json` and friends (PR #22).
- Append-only logs (`.scrum/hooks.log`, `.scrum/pbi/<id>/pipeline.log`) — line-formatted, no JSON schema.
