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
| `jq '.developers["dev-001-s1"].current_pbi = "pbi-007"' .scrum/sprint.json > tmp && mv ...` | `.scrum/scripts/set-sprint-developer.sh dev-001-s1 current_pbi pbi-007` (fields: `status`, `current_pbi`; `current_pbi_phase` was removed in v2 — read `backlog.json.items[<current_pbi>].status` instead) |
| `jq '.phase = "design"' .scrum/state.json > tmp && mv ...` | `.scrum/scripts/update-state-phase.sh design` |
| `jq '.messages += [{...}]' .scrum/communications.json > tmp && mv ...` | `.scrum/scripts/append-communication.sh --from <id> --to <id\|null> --kind <type> --content <text> [--role <role>] [--pbi <pbi-id>]` |
| `jq '.events += [{...}]' .scrum/dashboard.json > tmp && mv ...` | `.scrum/scripts/append-dashboard-event.sh --type <type> [--agent <id>] [--pbi <pbi-id>] [--file <path>] [--change-type <ct>] [--detail <text>] [--status-from <s>] [--status-to <s>]` |
| `update_state ".scrum/pbi/$PBI/" '.design_round = 1'` (PR #22 inline helper) | `.scrum/scripts/update-pbi-state.sh "$PBI" design_round 1` (variadic field/value pairs in one atomic write) |
| `printf '%s\t%s\t...\n' >> .scrum/pbi/$PBI/pipeline.log` | `.scrum/scripts/append-pbi-log.sh "$PBI" <stage> <round> <event> <detail>` |
| `jq '(.items[]\|select(.id==$id)).sprint_id = "sprint-NNN"' .scrum/backlog.json > tmp && mv ...` | `.scrum/scripts/set-backlog-item-field.sh "$PBI" sprint_id sprint-NNN` (also: `implementer_id`, `review_doc_path`, `catalog_targets`) |

`update-pbi-state.sh` accepts variadic field/value pairs (the `phase`
field was removed in v2; lifecycle moves through
`update-backlog-status.sh` instead):

```
.scrum/scripts/update-pbi-state.sh pbi-001 design_status pass impl_round 1
```

All pairs apply in a single atomic transaction (one schema validation, one `mv`).

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

1. **Sprint creation / init** (sprint-planning step 8) requires a fresh `.scrum/sprint.json`; no `init-sprint.sh` wrapper exists yet — the existing wrappers all assume the file is present (`E_FILE_MISSING` otherwise).
2. **Append-only siblings** — `.scrum/sprint-history.json`, `.scrum/improvements.json`, `.scrum/test-results.json`, `.scrum/session-map.json` have no schema and no wrapper. Out of scope for this PR; defer until the MVP soaks. The same exemption applies to `hooks/dashboard-event.sh::update_pbi_pipelines`, which raw-mutates the `pbi_pipelines` projection in `dashboard.json` from hook context (guard runs as PreToolUse and cannot intercept its own handler); a wrapper is desirable but not blocking.
3. **Read-side validation** — `dashboard/app.py` and the various hooks that read `.scrum/*.json` do not validate against the schemas. Defensive read-side patches (e.g. UnicodeDecodeError handling) stay; schema-driven validation is a future hardening pass.

Until gap #1 lands, sprint-planning step 8 (sprint.json creation) **will fail at runtime** when the hook fires. Steps 9 and 10.2 are now covered by `set-backlog-item-field.sh`.

## Worktree / merge governance wrappers (2026-05-04)

| Wrapper | Writes |
|---|---|
| `freeze-sprint-base.sh` | `sprint.base_sha`, `sprint.base_sha_captured_at` (once per Sprint) |
| `create-pbi-worktree.sh` | `pbi/<id>/state.json` `branch`, `worktree`, `base_sha`; creates git worktree + `.scrum` symlink |
| `commit-pbi.sh` | git commit on `pbi/<id>` branch + `pbi/<id>/state.json.head_sha` |
| `mark-pbi-ready-to-merge.sh` | `pbi/<id>/state.json` `head_sha`, `paths_touched`, `ready_at`; backlog item `status=in_progress_merge` |
| `mark-pbi-merged.sh` | `pbi/<id>/state.json` `merged_sha`, `merged_at`, `merge_failure_count=0`; backlog item `merged_sha`, `merged_at`, `status=awaiting_cross_review` |
| `mark-pbi-merge-failure.sh` | `pbi/<id>/state.json` `merge_failure` (with `kind ∈ {conflict, artifact_missing}`), `merge_failure_count++`; on 3rd consecutive failure sets `pbi-state.escalation_reason ∈ {merge_conflict, merge_artifact_missing}` and backlog `status=escalated` |
| `cleanup-pbi-worktree.sh` | removes git worktree + `pbi/<id>` branch (post-merge) |
| `merge-pbi.sh` | orchestrator (calls mark-pbi-merged or mark-pbi-merge-failure + cleanup) |

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

The one-shot migration was performed via `scripts/migrate-status-v2.sh`
(now removed; refer to git history if a deployed project still needs
it). The mapping table, run procedure, and caveats are preserved
under that commit's snapshot of this file.

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
