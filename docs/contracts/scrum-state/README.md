# `.scrum/` Sprint State Schemas (SSOT)

Each schema corresponds to one file under `.scrum/` and is the single source of truth for its on-disk shape today. Both the validated wrapper scripts (`.scrum/scripts/*.sh` in deployed projects; `scripts/scrum/*.sh` in this framework's source tree) and readers (dashboard, hooks) MUST validate against these schemas.

| File                                | Schema                                | Permitted writers (`.scrum/scripts/*.sh`)             |
|-------------------------------------|---------------------------------------|-------------------------------------------------------|
| `.scrum/state.json`                 | `state.schema.json`                   | `update-state-phase.sh`                               |
| `.scrum/sprint.json`                | `sprint.schema.json`                  | `update-sprint-status.sh`, `set-sprint-developer.sh`, `freeze-sprint-base.sh` |
| `.scrum/backlog.json`               | `backlog.schema.json`                 | `update-backlog-status.sh`, `set-backlog-item-field.sh`, `add-backlog-item.sh`; also `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh` (which delegate to `update-backlog-status.sh`) |
| `.scrum/communications.json`        | `communications.schema.json`          | `append-communication.sh` (agent-driven; caps at `max_messages` on append); **plus** `hooks/dashboard-event.sh` (`append_comms_message`) for hook-emitted events on the PostToolUse / SubagentStart-Stop / TeammateIdle / SendMessage hot-path. The hook writes directly through `lib/validate.sh::append_to_json_array` without re-validating against the schema per call. |
| `.scrum/dashboard.json`             | `dashboard.schema.json`               | `hooks/dashboard-event.sh` via `hooks/lib/dashboard.sh::append_dashboard_event` only. **No `.scrum/scripts/*.sh` wrapper** — the dashboard is hook-only telemetry on a latency-sensitive hot-path. Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`; schema is enforced when the file is initially created (`ensure_dashboard_file`), not re-validated per append. |
| `.scrum/pbi/<id>/state.json`        | `pbi-state.schema.json`               | `init-pbi-state.sh` (initial), `update-pbi-state.sh` (low-level); higher-level callers: `create-pbi-worktree.sh`, `commit-pbi.sh`, `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh` |
| `.scrum/config.json`                | `config.schema.json`                  | User (manual edit, interactive mode) **or** `scrum-start.sh --autonomous` (merges `po_mode`, `po`, `autonomous` defaults). Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`. No wrapper script. |
| `.scrum/autonomy.json`              | `autonomy.schema.json`                | `scripts/autonomous/watchdog.sh` (atomic tmp+mv) and the hook library `hooks/lib/autonomy.sh` (`bump_stop_block_counter`, `record_circuit_breaker`). **No `.scrum/scripts/*.sh` wrapper** — the runtime hot-path is latency-sensitive. Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`; schema is enforced by the watchdog on rotation, not per call. |
| `.scrum/po/decisions.json`          | `po-decisions.schema.json`            | `append-po-decision.sh` only. Append-only; ids auto-assigned (`dec-NNNN`). Wrapper enforces evidence requirement for `kind ∈ {demo_acceptance, uat_item, release_decision}` and the green-tests gate for `release_decision=go`. |
| `.scrum/stop-gate.json`             | `stop-gate.schema.json`               | `hooks/lib/stop-gate-state.sh` (`stop_gate_check_and_bump`), sourced by `hooks/completion-gate.sh`. **Human-mode only** dedup ledger — absent under autonomous mode. **No `.scrum/scripts/*.sh` wrapper** — the hook process runs outside the `pre-tool-use-scrum-state-guard.sh` intercept. Atomic tmp + mv writes; fail-open toward block on any I/O failure. |

Orchestrators (`merge-pbi.sh`, `merge-main-into-pbi.sh`, `safe-switch-to-main.sh`, `cleanup-pbi-worktree.sh`, `migrate-legacy.sh`) drive git operations and the writers above; they do not bypass the schema-validated writes.

## Design choices

- **Top-level `additionalProperties: true`** — top-level objects routinely grow (`max_events`, `max_messages`, etc.). Permissive at the root catches drift via item-level strictness without requiring lockstep schema bumps for new top-level config.
- **Item-level `additionalProperties: false`** — array items (PBIs, developers, messages, events) are where typos cause silent dashboard breakage. Strict here.
- **No `schema_version` field** — YAGNI. Existing files don't carry one. Add if/when an incompatible migration is actually needed.
- **Mirror today's shape exactly** — every field name in the fixtures and writers is allowed; no aspirational renames.

## Out of scope (covered elsewhere)

- PBI sub-agent envelopes — see `docs/contracts/pbi-pipeline-envelope.schema.json` and friends (PR #22).
- Append-only logs (`.scrum/hooks.log`, `.scrum/pbi/<id>/pipeline.log`) — line-formatted, no JSON schema.
