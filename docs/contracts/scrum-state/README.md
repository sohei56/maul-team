# `.scrum/` Sprint State Schemas (SSOT)

Each schema corresponds to one file under `.scrum/` and is the single source of truth for its on-disk shape today. **Normative target:** the validated wrapper scripts (`.scrum/scripts/*.sh` in deployed projects; `scripts/scrum/*.sh` in this framework's source tree) validate against these schemas on every write. Two documented exceptions to that rule (see the table below): (1) the hot-path, hook-owned appenders — `communications.json`, `dashboard.json`, `autonomy.json` (rows for those files) — validate the schema only when the file is first created (or on rotation), not per append, to keep the latency-sensitive path cheap; and (2) readers (dashboard, hooks, statusline) do **not** re-validate — they trust the wrapper-written shape. Treat "wrappers validate on write" as the invariant to preserve; the per-append and reader skips are deliberate, table-documented carve-outs, not a license to add unvalidated writers.

| File                                | Schema                                | Permitted writers (`.scrum/scripts/*.sh`)             |
|-------------------------------------|---------------------------------------|-------------------------------------------------------|
| `.scrum/state.json`                 | `state.schema.json`                   | `init-state.sh` (initial seed), `update-state-phase.sh`, `init-sprint.sh` (sets `current_sprint_id`), `migrate-legacy.sh` |
| `.scrum/sprint.json`                | `sprint.schema.json`                  | `init-sprint.sh` (initial seed), `update-sprint-status.sh`, `set-sprint-developer.sh`, `freeze-sprint-base.sh`, `migrate-legacy.sh` |
| `.scrum/backlog.json`               | `backlog.schema.json`                 | `init-backlog.sh` (initial seed), `update-backlog-status.sh` (additionally gates the transition into `refined` on a non-empty `demo_plan` for `kind=code` items), `set-backlog-item-field.sh`, `add-backlog-item.sh`, `migrate-legacy.sh`, `migrate-add-kind-field.sh` (idempotent atomic `kind: "code"` backfill; auto-run by `scrum-start.sh` at launch); also `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh`, `begin-impl-round.sh` (which delegate to `update-backlog-status.sh`) |
| `.scrum/communications.json`        | `communications.schema.json`          | `hooks/dashboard-event.sh` (`append_comms_message`) only — hook process, outside the agent tool surface — for hook-emitted events on the PostToolUse / SubagentStart-Stop / TeammateIdle / SendMessage hot-path. The hook writes directly through `lib/validate.sh::append_to_json_array` without re-validating against the schema per call. **No `.scrum/scripts/*.sh` wrapper** — the former message-append wrapper had zero runtime invokers and was retired (see `MIGRATION-scrum-state-tools.md`). |
| `.scrum/dashboard.json`             | `dashboard.schema.json`               | `hooks/dashboard-event.sh` via `hooks/lib/dashboard.sh::append_dashboard_event` only. **No `.scrum/scripts/*.sh` wrapper** — the dashboard is hook-only telemetry on a latency-sensitive hot-path. Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`; schema is enforced when the file is initially created (`ensure_dashboard_file`), not re-validated per append. |
| `.scrum/pbi/<id>/state.json`        | `pbi-state.schema.json`               | `init-pbi-state.sh` (initial), `update-pbi-state.sh` (low-level), `begin-impl-round.sh` (round bump + status transition); higher-level callers: `create-pbi-worktree.sh`, `commit-pbi.sh`, `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh` |
| `.scrum/config.json`                | `config.schema.json`                  | User (manual edit, interactive mode) **or** `scrum-start.sh --autonomous` (merges `po_mode`, `po`, `autonomous` defaults). Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`. No wrapper script. |
| `.scrum/autonomy.json`              | `autonomy.schema.json`                | `scrum-start.sh --autonomous` (initial seed in the run-launcher block), `scripts/autonomous/watchdog.sh` (atomic tmp+mv), and the hook library `hooks/lib/autonomy.sh` (`bump_stop_block_counter`, `record_circuit_breaker`). **No `.scrum/scripts/*.sh` wrapper** — the runtime hot-path is latency-sensitive. Agent direct edits are blocked by `pre-tool-use-scrum-state-guard.sh`; schema is enforced by the watchdog on rotation, not per call. |
| `.scrum/po/decisions.json`          | `po-decisions.schema.json`            | `append-po-decision.sh` only. Append-only; ids auto-assigned (`dec-NNNN`). Wrapper enforces evidence requirement for `kind ∈ {demo_acceptance, uat_item, release_decision}` and the green-tests gate for `release_decision=go`. |
| `.scrum/improvements.json`          | `improvements.schema.json`            | `append-improvement.sh` (append; auto-assigned `imp-NNNN`; optional `dec_id` links to a `po-decisions.json` record) and `consolidate-improvements.sh` (3-Sprint consolidation: flips Retrospective-named entries to `status: archived` with `archived_at`, bumps `last_consolidation_sprint`; one atomic, schema-validated write). |
| `.scrum/sprint-history.json`        | `sprint-history.schema.json`          | `append-sprint-history.sh` only (append; `--id`/`--goal` required, optional `--type`/`--pbis-completed`/`--pbis-total`/`--started-at`/`--completed-at`); driven at Sprint rollover by `rollover-sprint.sh`, which archives the completed `sprint.json` via this append and then deletes `.scrum/sprint.json` so `init-sprint.sh` can seed the next Sprint. Idempotent on `--id` so a retried Sprint Review never double-counts a Sprint in the watchdog `max_sprints` tally. Read by `completion-gate.sh` (sprint_review exit criterion), `watchdog.sh`, the dashboard, and `statusline.sh`. |
| `.scrum/test-results.json`          | `test-results.schema.json`            | `record-test-result.sh` only (`--name`/`--status` required, optional `--total`/`--passed`/`--failed`/`--skipped`/`--runner-command`/`--executed-at`/repeatable `--error 'NAME::msg'`). Upsert by `--name` (a suite re-run replaces its category, so the release gate sees fresh counts); creates the file on first call and recomputes `overall_status` on every call. Written by the `smoke-test` and `integration-tests` skills; read by `completion-gate.sh` (`integration_sprint` exit + `uat_release` regression check), `append-po-decision.sh` (`release_decision=go` gate), the `uat-release` skill's precondition check, the `po-acceptance` skill (UAT gate), and the dashboard. |
| `.scrum/stop-gate.json`             | `stop-gate.schema.json`               | `hooks/lib/stop-gate-state.sh` (`stop_gate_check_and_bump`), sourced by `hooks/completion-gate.sh`. **Human-mode only** dedup ledger — absent under autonomous mode. **No `.scrum/scripts/*.sh` wrapper** — the hook process runs outside the `pre-tool-use-scrum-state-guard.sh` intercept. Atomic tmp + mv writes; fail-open toward block on any I/O failure. |

Orchestrators (`merge-pbi.sh`, `merge-main-into-pbi.sh`, `safe-switch-to-main.sh`, `cleanup-pbi-worktree.sh`, `rollover-sprint.sh`, `migrate-legacy.sh`) drive git operations and the writers above; they do not bypass the schema-validated writes. `rollover-sprint.sh` additionally deletes `.scrum/sprint.json` after archiving it (the sole sanctioned state-file deletion; refuses unless `sprint.json.status == "complete"`). `commit-integration-tests.sh` (used by the `integration-tests` skill) is a git-only commit wrapper for the target project's test assets — it writes no `.scrum/*.json` file, so it has no row above; see `MIGRATION-scrum-state-tools.md` § Worktree / merge governance wrappers.

## Design choices

- **Top-level `additionalProperties: true`** — top-level objects routinely grow (`max_events`, `max_messages`, etc.). Permissive at the root catches drift via item-level strictness without requiring lockstep schema bumps for new top-level config.
- **Item-level `additionalProperties: false`** — array items (PBIs, developers, messages, events) are where typos cause silent dashboard breakage. Strict here.
- **No `schema_version` field** — YAGNI. Existing files don't carry one. Add if/when an incompatible migration is actually needed.
- **Mirror today's shape exactly** — every field name in the fixtures and writers is allowed; no aspirational renames.

## Out of scope (covered elsewhere)

- PBI sub-agent envelopes — see `docs/contracts/pbi-pipeline-envelope.schema.json` and friends (PR #22).
- Append-only logs (`.scrum/hooks.log`, `.scrum/pbi/<id>/pipeline.log`) — line-formatted, no JSON schema.
- **No-schema SSOT siblings.** Several runtime files live under
  `.scrum/` without their own JSON Schema and are intentionally
  absent from the table above: `.scrum/runtime.json` (tmux session
  + SM pane id + stall-watchdog PID, written by `scrum-start.sh`)
  and `.scrum/session-map.json` (autonomous-mode iteration → session
  id ledger). They match the guard's `.scrum/**/*.json` pattern but
  their writers run outside the agent tool surface (launcher script),
  so the guard never intercepts them. Schemas are out of scope until
  a reader-side bug demands them — see
  `MIGRATION-scrum-state-tools.md` § Known gaps. (Historical note:
  `.scrum/improvements.json`, `.scrum/sprint-history.json`, and
  `.scrum/test-results.json` were all in this list until
  autonomous-mode ceremonies surfaced that the retrospective,
  sprint-review, smoke-test, and design-completeness-check (now
  integration-tests) skills
  write them via the agent tool surface and *are* intercepted by the
  guard — an unblocked Integration Sprint could not persist test
  results. Each now has a schema + a wrapper per the table above.)
