# `.scrum/` Sprint State Schemas (SSOT)

Each schema corresponds to one file under `.scrum/` and is the single source of truth for its on-disk shape today. Both the validated wrapper scripts (`.scrum/scripts/*.sh` in deployed projects; `scripts/scrum/*.sh` in this framework's source tree) and readers (dashboard, hooks) MUST validate against these schemas.

| File                                | Schema                                | Permitted writers (`.scrum/scripts/*.sh`)             |
|-------------------------------------|---------------------------------------|-------------------------------------------------------|
| `.scrum/state.json`                 | `state.schema.json`                   | `update-state-phase.sh`                               |
| `.scrum/sprint.json`                | `sprint.schema.json`                  | `update-sprint-status.sh`, `set-sprint-developer.sh`, `freeze-sprint-base.sh` |
| `.scrum/backlog.json`               | `backlog.schema.json`                 | `update-backlog-status.sh`, `set-backlog-item-field.sh`, `add-backlog-item.sh`; also `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh` (which delegate to `update-backlog-status.sh`) |
| `.scrum/communications.json`        | `communications.schema.json`          | `append-communication.sh`                             |
| `.scrum/dashboard.json`             | `dashboard.schema.json`               | `append-dashboard-event.sh`                           |
| `.scrum/pbi/<id>/state.json`        | `pbi-state.schema.json`               | `init-pbi-state.sh` (initial), `update-pbi-state.sh` (low-level); higher-level callers: `create-pbi-worktree.sh`, `commit-pbi.sh`, `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh` |

Orchestrators (`merge-pbi.sh`, `merge-main-into-pbi.sh`, `safe-switch-to-main.sh`, `cleanup-pbi-worktree.sh`, `migrate-legacy.sh`) drive git operations and the writers above; they do not bypass the schema-validated writes.

## Design choices

- **Top-level `additionalProperties: true`** — top-level objects routinely grow (`max_events`, `max_messages`, etc.). Permissive at the root catches drift via item-level strictness without requiring lockstep schema bumps for new top-level config.
- **Item-level `additionalProperties: false`** — array items (PBIs, developers, messages, events) are where typos cause silent dashboard breakage. Strict here.
- **No `schema_version` field** — YAGNI. Existing files don't carry one. Add if/when an incompatible migration is actually needed.
- **Mirror today's shape exactly** — every field name in the fixtures and writers is allowed; no aspirational renames.

## Out of scope (covered elsewhere)

- PBI sub-agent envelopes — see `docs/contracts/pbi-pipeline-envelope.schema.json` and friends (PR #22).
- Append-only logs (`.scrum/hooks.log`, `.scrum/pbi/<id>/pipeline.log`) — line-formatted, no JSON schema.
