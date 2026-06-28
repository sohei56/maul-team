# Migration: `.scrum/` raw edits → `.scrum/scripts/*` wrappers

## What changed

Agents must no longer edit `.scrum/*.json` directly. All writes flow through validated wrapper scripts under `.scrum/scripts/` that take a directory lock, apply a `jq` expression, validate the result against a JSON Schema in `docs/contracts/scrum-state/`, and write atomically (`tmp` + `mv`). A `PreToolUse` hook blocks bypass attempts (`Write`, `Edit`, raw redirects, `jq -i`, `sed -i`) on `.scrum/**/*.json`.

> **Layout note** — In deployed projects the wrappers live at `.scrum/scripts/*.sh` (placed there by `setup-user.sh` to keep them out of the user's own `scripts/` tree). Inside this framework's own source tree they live at `scripts/scrum/*.sh`; both invocation styles work because neither matches the guard's block patterns.

## Mapping

| Old (raw) | New (validated wrapper) |
|---|---|
| `jq '(.items[] | select(.id == "$PBI")).status = "in_progress_design"' .scrum/backlog.json > tmp && mv tmp .scrum/backlog.json` | `.scrum/scripts/update-backlog-status.sh "$PBI" in_progress_design` |
| Same pattern for any of the 12 v2 statuses | `.scrum/scripts/update-backlog-status.sh "$PBI" {draft\|refined\|blocked\|in_progress_design\|in_progress_impl\|in_progress_pbi_review\|in_progress_ut_run\|in_progress_merge\|awaiting_cross_review\|cross_review\|escalated\|done}` |
| `jq '.items += [{id:"pbi-NNN",title:"...",status:"draft",...}] \| .next_pbi_id += 1' .scrum/backlog.json > tmp && mv ...` | `.scrum/scripts/add-backlog-item.sh --title <text> [--description <text>] [--ac <criterion>]... [--parent <pbi-id>] [--ux-change]` (allocates id from `next_pbi_id`, prints new pbi-id to stdout) |
| `jq '.status = "active"' .scrum/sprint.json > tmp && mv tmp .scrum/sprint.json` | `.scrum/scripts/update-sprint-status.sh active` (also: `planning`, `cross_review`, `sprint_review`, `complete`, `failed`) |
| `jq '.developers["dev-001-s1"].current_pbi = "pbi-007"' .scrum/sprint.json > tmp && mv ...` | `.scrum/scripts/set-sprint-developer.sh dev-001-s1 current_pbi pbi-007` (fields: `status`, `current_pbi`, `assigned_work` (JSON object), `sub_agents` (JSON array); `current_pbi_phase` was removed in v2 — read `backlog.json.items[<current_pbi>].status` instead) |
| `jq '.phase = "pbi_pipeline_active"' .scrum/state.json > tmp && mv ...` | `.scrum/scripts/update-state-phase.sh pbi_pipeline_active` |
| `mkdir -p .scrum && jq -n '{phase:"new",...}' > .scrum/state.json` (initial bootstrap of a fresh project) | `.scrum/scripts/init-state.sh` (idempotent; no-op if `.scrum/state.json` already exists) |
| `jq -n '{items:[],next_pbi_id:1,product_goal:"..."}' > .scrum/backlog.json` (Requirements Sprint step 6 seed) | `.scrum/scripts/init-backlog.sh [--product-goal <text>]` (idempotent; no-op if `.scrum/backlog.json` already exists) |
| `jq '.messages += [{...}]' .scrum/communications.json > tmp && mv ...` | `.scrum/scripts/append-communication.sh --from <id> --to <id\|null> --kind <type> --content <text> [--role <role>] [--pbi <pbi-id>]` (caps at `max_messages` on append; mirrors the hook-side cap so wrapper- and hook-emitted messages share retention) |
| `jq '.events += [{...}]' .scrum/dashboard.json > tmp && mv ...` | **Removed**: `.scrum/dashboard.json` is hook-only telemetry written by `hooks/dashboard-event.sh` via `hooks/lib/dashboard.sh::append_dashboard_event`. No agent-callable wrapper. Agents instead emit dashboard signals indirectly via the tools they use (PostToolUse / SendMessage / SubagentStop). |
| `update_state ".scrum/pbi/$PBI/" '.design_round = 1'` (PR #22 inline helper) | `.scrum/scripts/update-pbi-state.sh "$PBI" design_round 1` (variadic field/value pairs in one atomic write) |
| `printf '%s\t%s\t...\n' >> .scrum/pbi/$PBI/pipeline.log` | `.scrum/scripts/append-pbi-log.sh "$PBI" <stage> <round> <event> <detail>` |
| `jq '(.items[]\|select(.id==$id)).sprint_id = "sprint-NNN"' .scrum/backlog.json > tmp && mv ...` | `.scrum/scripts/set-backlog-item-field.sh "$PBI" sprint_id sprint-NNN` (also: `implementer_id`, `review_doc_path`, `catalog_targets`, `priority`, `description`, `ux_change`, `acceptance_criteria`, `design_doc_paths`, `depends_on_pbi_ids`, `kind`) |
| Create `.scrum/sprint.json` at planning AND set `state.current_sprint_id` (was: raw `jq` + `mv` + separate `update-state-phase.sh` pair, which leaked the lag bug surfaced by IMP-003/IMP-009/imp-s28-02) | `.scrum/scripts/init-sprint.sh <sprint-id> [--goal <goal>] [--type development\|integration]` (writes both files; refuses if `sprint.json` already exists) |
| Append one SprintSummary to `.scrum/sprint-history.json` (was: raw `jq` append the scrum-state guard blocks) | `.scrum/scripts/append-sprint-history.sh --id <sprint-id> --goal <text> [--type ...] [--pbis-completed N] [--pbis-total N] [--started-at <iso>] [--completed-at <iso>]` (append-only, idempotent on `--id`) |
| Advance from a completed Sprint to the next (was: **no wrapper** — `init-sprint.sh` refused while `sprint.json` existed and `freeze-sprint-base.sh` refused while `base_sha` was frozen, leaving the team unable to start any Sprint after Sprint 1) | `.scrum/scripts/rollover-sprint.sh` (archives the `status: complete` `sprint.json` to `sprint-history.json`, then removes `sprint.json` so `init-sprint.sh` + `freeze-sprint-base.sh` can start the next Sprint on a fresh base; refuses a non-complete Sprint; idempotent no-op when no `sprint.json`) |

`update-pbi-state.sh` accepts variadic field/value pairs (the `phase`
field was removed in v2; lifecycle moves through
`update-backlog-status.sh` instead):

```
.scrum/scripts/update-pbi-state.sh pbi-001 design_status pass impl_round 1
```

All pairs apply in a single atomic transaction (one schema validation, one `mv`).

### Removed: `sprint.json.pbi_ids` and `sprint.json.developer_count` (OD-4, 2026-06)

These two fields were derivable from other state, so they violated the
single-source rule that drove the v2 status unification:

- **Sprint PBI membership** is now derived from `backlog.json.items[]`
  where `sprint_id == sprint.json.id`. The Scrum Master writes the
  assignment via `set-backlog-item-field.sh "$PBI_ID" sprint_id <sprint-id>`
  during Sprint Planning; no `pbi_ids` array is maintained on the sprint side.
- **Developer count** is `sprint.json.developers | length` — `developer_count`
  was a redundant cache that could drift if the developers array was edited
  out of band.

`init-sprint.sh` no longer seeds either field. Readers (`completion-gate.sh`,
`statusline.sh`, the dashboard, `sprint-planning` / `spawn-teammates` skills)
all derive. `sprint.schema.json.additionalProperties: true` means
pre-existing files retaining the old fields continue to validate; nothing
reads them.

### `impl_round` advancement (`begin-impl-round.sh`)

Even though `update-pbi-state.sh` accepts `impl_round` as a settable
field, the impl/PBI-review/UT-run pipeline MUST advance the counter
via the dedicated wrapper:

```
n=$(.scrum/scripts/begin-impl-round.sh pbi-001)
```

This one wrapper owns: increment `impl_round`, reset `impl_status`
and `ut_status` to `pending`, and (idempotently) set backlog status
to `in_progress_impl`. It is idempotent on respawn (returns current
`impl_round` without mutation when `impl_status == "pending"` AND
`impl_round > 0`). It refuses to start from illegal pre-states
(anything other than `in_progress_design`, `in_progress_pbi_review`,
`in_progress_ut_run`, `cross_review`, `in_progress_impl`).

Rationale: a Cross Review aspect-1/2/3 FAIL reverts the PBI to
`in_progress_impl` without touching `state.json.impl_round`. When the
counter was computed by the agent (LLM reads `impl_round`, adds 1,
writes back), this re-entry path was undocumented and the conductor
restarted at Round 1 — observable as the dashboard's Round column
regressing from N to 1. Centralising the counter in a wrapper makes
that regression structurally impossible. Direct
`update-pbi-state.sh ... impl_round <N>` is still accepted (for
migration tooling and tests) but is forbidden during the live
pipeline.

## What enforces this

`hooks/pre-tool-use-scrum-state-guard.sh` is registered as a `PreToolUse` hook in `.claude/settings.json` (matcher: `Write|Edit|MultiEdit|Bash`). It blocks:

- `Write` / `Edit` / `MultiEdit` on `.scrum/**/*.json`. The path is normalized against `$PWD` first, so `./.scrum/x.json`, `$PWD/.scrum/x.json`, and `.scrum/./pbi/.//state.json` are all caught (not just the bare relative form).
- `Bash` commands that redirect (`>`, `>>`, `tee`, `sponge`) into `.scrum/*.json`
- `Bash` with `jq -i`, `sed -i`, or `awk -i inplace` on `.scrum/*.json`
- `Bash` with `mv X .scrum/*.json` or `cp X .scrum/*.json` (the second half of the redirect-then-rename pattern)
- `Bash` with `truncate ... .scrum/*.json`

The destination match works on absolute paths too (`mv /tmp/x $PWD/.scrum/y.json` is blocked, not just `mv /tmp/x .scrum/y.json`).

Wrapper invocations (`.scrum/scripts/foo.sh args` or `scripts/scrum/foo.sh args`) **are not whitelisted** — they pass naturally because their argv contains none of the block keywords. This intentional design closes the v1 bypass where an agent could include `# .scrum/scripts/...` as a comment alongside a raw write and have the entire command short-circuit to `allow`.

The threat model is **honest agent**, not adversary. Sophisticated obfuscation (variable substitution, `eval`, `bash -c`, base64-encoded commands) can still bypass the regex-based check; this is acceptable for the project's threat model.

## Failure modes

| Exit code | Constant | Meaning |
|---|---|---|
| `64` | `E_INVALID_ARG` | Bad CLI argument (unknown field, malformed PBI id, wrong arity, etc.) |
| `65` | `E_SCHEMA` | The post-mutation document violates its JSON Schema |
| `66` | `E_LOCK_TIMEOUT` | Could not acquire `.scrum/.locks/<file>.lock.d` within `SCRUM_LOCK_TIMEOUT` seconds (default 10) |
| `67` | `E_FILE_MISSING` | The target `.scrum/*.json` file does not exist (init it via the relevant ceremony first) |
| `68` | `E_NO_VALIDATOR` | No JSON Schema validator was found on the host |

All errors print `[scrum-tool] <CONST>: <message>` to stderr.

## Reading stays free

Read access is **not** enforced. `cat .scrum/state.json | jq ...` is fine. The schemas under `docs/contracts/scrum-state/` are the read-side contract — clients (the dashboard, hooks, sub-agents) should validate or assume the documented shape.

## Schema validator setup

The wrappers probe for a JSON Schema validator at runtime via `lib/check-validator.sh` (alongside the wrappers). Preference order:

1. `npx ajv-cli` (preferred — installs on demand if `npx` is present)
2. `check-jsonschema` (pipx)
3. `jsonschema` CLI (deprecated upstream but functional)
4. Python `jsonschema` module

`scripts/setup-dev.sh` probes and reports the resolved runner. CI / test runs that need determinism set `SCRUM_VALIDATOR_OVERRIDE` to one of `ajv`, `check-jsonschema`, `jsonschema-cli`, `python` to bypass auto-detection. If none of the four runners is available, every wrapper exits `68` (`E_NO_VALIDATOR`).

## Known gaps (follow-ups)

The current wrapper set covers the pbi-pipeline migration, the four migrated skill SKILL files, and the sprint-planning per-PBI item-field updates. Remaining gaps:

1. ~~**Sprint creation / init** (sprint-planning step 8) requires a fresh `.scrum/sprint.json`; no `init-sprint.sh` wrapper exists yet — the existing wrappers all assume the file is present (`E_FILE_MISSING` otherwise).~~ **Resolved**: `init-sprint.sh` lands `.scrum/sprint.json` AND updates `state.current_sprint_id` atomically per call. Closes the recurring `current_sprint_id` lag bug surfaced by retrospectives across target projects (IMP-003 / IMP-009 / imp-s28-02).
2. **Append-only siblings** — `.scrum/test-results.json` and `.scrum/session-map.json` have no schema and no wrapper. Out of scope for this PR; defer until the MVP soaks. ~~`.scrum/improvements.json`~~ **Resolved**: surfaced when an autonomous-mode Retrospective hit the `pre-tool-use-scrum-state-guard.sh` block writing the entry. `improvements.schema.json` + `append-improvement.sh` land the missing wrapper (auto-assigned `imp-NNNN`, optional `dec_id` for the `po_mode=agent` `PO_DECISION_REQUEST → improvement` linkage). 3-Sprint consolidation (`status: archived`, `archived_at`, `last_consolidation_sprint` bump) is still wrapper-less; not required until Sprint 4 hits — `consolidate-improvements.sh` is a follow-up. ~~`.scrum/sprint-history.json`~~ **Resolved**: same failure mode — `sprint-review` SKILL step 7 instructs an append the guard then blocks, and `completion-gate.sh` makes the `sprint_review` exit hinge on the entry existing (so a missing wrapper can stall the Stop gate, not just lose data). `sprint-history.schema.json` + `append-sprint-history.sh` land the wrapper (`--id`/`--goal` required, optional `--type`/`--pbis-completed`/`--pbis-total`/`--started-at`/`--completed-at`; idempotent on `--id` so a retried Review never double-counts a Sprint in the watchdog `max_sprints` tally).
3. **Read-side validation** — `dashboard/app.py` and the various hooks that read `.scrum/*.json` do not validate against the schemas. Defensive read-side patches (e.g. UnicodeDecodeError handling) stay; schema-driven validation is a future hardening pass.
4. **`TeammateIdle` hook gate as the source-level fix for silent-death teammates.** The current `scripts/stall-watchdog.sh` daemon catches the *symptom* (no `.scrum/dashboard.json` / `.scrum/pbi/*/` mtime change inside `idle_threshold_minutes`) but the *cause* — Agent-tool teammates terminating without surfacing the cause to the SM — is not handled at the source. A cleaner fix is to gate `TeammateIdle` events in a hook so the SM is woken with the actual `reason`/`exit-code` payload instead of inferring liveness from filesystem mtimes. **Blocker for the spike**: the `TeammateIdle` payload contract (which fields are guaranteed, when the event fires, what `reason` values exist) is not documented in any current Claude Code reference — needs a live-CLI spike on a recent release to nail down the schema before the hook can be written. Until then the external watchdog stands in.
5. **Single-Stop-hook display verification.** The dispatcher (`hooks/stop-dispatch.sh`) folds two registered Stop hooks into one to reduce the Claude Code session UI's `"Ran 2 stop hooks"` notification to `"Ran 1 stop hook"`. The wording, the threshold for plural-vs-singular, and whether the timeline counts the dispatcher-spawned child processes as separate hooks are all **unofficial implementation details** of the CLI's session UI — not part of any public contract. The display change after the rollout has therefore been reasoned through but not verified against a live session; the first autonomous-mode dogfooding run should confirm the count drops to 1 (or note the actual observed wording for follow-up).

## Worktree / merge governance wrappers (2026-05-04)

| Wrapper | Writes |
|---|---|
| `freeze-sprint-base.sh` | `sprint.base_sha`, `sprint.base_sha_captured_at` (once per Sprint) |
| `create-pbi-worktree.sh` | `pbi/<id>/state.json` `branch`, `worktree`, `base_sha`; creates git worktree + `.scrum` symlink |
| `commit-pbi.sh` | git commit on `pbi/<id>` branch + `pbi/<id>/state.json.head_sha` |
| `mark-pbi-ready-to-merge.sh` | `pbi/<id>/state.json` `head_sha`, `paths_touched`, `ready_at`; backlog item `status=in_progress_merge` |
| `mark-pbi-merged.sh` | `pbi/<id>/state.json` `merged_sha`, `merged_at`, `merge_failure_count=0`; backlog item `merged_sha`, `merged_at`, `status=awaiting_cross_review` |
| `mark-pbi-merge-failure.sh` | `pbi/<id>/state.json` `merge_failure` (with `kind ∈ {conflict, artifact_missing, regression}`), `merge_failure_count++`; on 3rd consecutive failure sets `pbi-state.escalation_reason ∈ {merge_conflict, merge_artifact_missing, merge_regression}` and backlog `status=escalated` |
| `cleanup-pbi-worktree.sh` | removes git worktree + `pbi/<id>` branch (post-merge) |
| `merge-pbi.sh` | orchestrator (calls mark-pbi-merged or mark-pbi-merge-failure + cleanup) |
| `merge-main-into-pbi.sh` | no state writes — merges main HEAD into the PBI worktree (SM conflict-recovery step after a `conflict` merge failure; see `skills/pbi-merge/SKILL.md`) |
| `safe-switch-to-main.sh` | no state writes — guarded `git checkout main` recovery wrapper (see `agents/scrum-master.md`) |

### Backward compatibility (sprints in flight at the merge-governance upgrade)

When the worktree-merge wrappers landed, `cross-review` started to
require every Sprint PBI to be merged first. PBIs from sprints that
finished under the older flow may have been at `phase=complete` or
`phase=review_complete` with no `branch` / `worktree` / `base_sha` in
`state.json`. Two recovery options were documented at that time:

- (A) Let the in-flight sprint finish under the old flow, then advance
  each PBI's `backlog.status` to `awaiting_cross_review` (formerly
  `phase=merged`) before running `cross-review` and `sprint-review`.
- (B) Drop the in-flight sprint and replan.

This guidance is preserved for archive purposes; the v2 status
migration below supersedes it for any project still on a v1 schema.

## v1 → v2 status migration (historical, 2026-05-06)

The v1 schema split PBI lifecycle across two fields:
`backlog.json.items[].status` (6 values) and
`pbi-state.json.phase` (10 values, including merge sub-states). v2
unifies these into a single 12-value `status` enum and removes the
`phase` field entirely.

The one-shot migration is now performed via
`scripts/scrum/migrate-legacy.sh`, which folds the v1→v2 status remap
into the broader legacy-cleanup pass (lowercases enum casing, drops
removed fields, etc.). The previously-named
`scripts/migrate-status-v2.sh` was retired in favour of that single
entry point; the original status mapping table, run procedure, and
caveats are preserved under the retiring commit's snapshot of this
file. Concretely: `in_progress → in_progress_design` and
`review → awaiting_cross_review` are applied in
`migrate-legacy.sh`'s backlog branch.

The dashboard event type `phase_transition` was renamed to
`status_transition` in v2. New writes always use `status_transition`
(the schema enum no longer accepts `phase_transition`). Old in-place
entries with the legacy type are not migrated, but the dashboard
reader (`dashboard/app.py`) does not schema-validate
`.scrum/dashboard.json` on read, and the file's `max_events` cap
naturally evicts pre-v2 entries within a few Sprints. The Sprint-end
`cross-review` precondition is now `status ∈
{awaiting_cross_review, escalated}` (formerly
`phase ∈ {merged, escalated}`).

## v2 → v3: `kind` field on PBI items (2026-06-14)

The doc-only PBI flow (planning: `docs/superpowers/plans/2026-06-13-doc-only-pbi-flow.md`)
adds a `kind` field to `backlog.json.items[]` and adds the `skipped`
enum value to `pbi-state.json.{design_status, ut_status,
coverage_status}` plus `kind_mismatch` to `escalation_reason`. PBIs
whose `paths_touched ⊆ **/*.md` (`kind="docs"`) skip the Design
stage and the entire UT pipeline (UT author, UT reviewer, UT Run,
coverage gate, AC coverage gate); only `pbi-implementer` +
`codex-impl-reviewer` run.

### Backward compatibility

- `backlog.schema.json` declares `kind` with `default: "code"`.
  Items that lack the field validate fine; readers that need the
  value substitute `"code"` via `(.kind // "code")`. The boundary
  enforce at `mark-pbi-ready-to-merge.sh` reads `kind` the same way.
- Existing `pbi-state.json` files validate against the new enum
  because `skipped` is an addition, not a removal.
- No legacy field is removed.

### One-shot migration

For consistency in dashboards and refinement audit logging,
backfill an explicit `kind: "code"` on every existing item:

```bash
.scrum/scripts/migrate-add-kind-field.sh
```

The wrapper is idempotent (second run prints `no-op`). It refuses
to write items that already have any `kind` value (so a
hand-tagged `kind: "docs"` survives untouched). The framework
repository's own `.scrum/backlog.json` (used by integration tests)
is also a valid target — running the migration there before
shipping the changes keeps fixtures honest.

### Operator checklist

1. Pull the framework repo to a revision that includes PR-1 .. PR-5.
2. Re-run `setup-user.sh <target>` so the target project picks up
   the updated `scripts/scrum/*.sh` (including
   `migrate-add-kind-field.sh`) and the schema files.
3. In the target project, run
   `.scrum/scripts/migrate-add-kind-field.sh`.
4. Optionally hand-promote already-doc-shaped PBIs to
   `kind="docs"` via
   `.scrum/scripts/set-backlog-item-field.sh <pbi-id> kind docs`.
   This is purely cosmetic until those PBIs re-enter the pipeline;
   the next time they do, the pipeline reads `kind` and routes
   accordingly.

### No reverse migration

`kind="docs"` is a forward-only tag. There is no automated
demotion to `code` — the only way to undo a `kind="docs"`
classification on a PBI mid-pipeline is to manually call
`set-backlog-item-field.sh kind code` AND restart the pipeline
(the wrapper does not reset `*_status` skipped values). In
practice this never matters: kind is determined per-PBI by
refinement, and refinement happens once.
