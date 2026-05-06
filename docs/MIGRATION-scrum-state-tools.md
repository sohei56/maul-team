# Migration: `.scrum/` raw edits → `.scrum/scripts/*` wrappers

## What changed

Agents must no longer edit `.scrum/*.json` directly. All writes flow through validated wrapper scripts under `.scrum/scripts/` that take a directory lock, apply a `jq` expression, validate the result against a JSON Schema in `docs/contracts/scrum-state/`, and write atomically (`tmp` + `mv`). A `PreToolUse` hook blocks bypass attempts (`Write`, `Edit`, raw redirects, `jq -i`, `sed -i`) on `.scrum/**/*.json`.

> **Layout note** — In deployed projects the wrappers live at `.scrum/scripts/*.sh` (placed there by `setup-user.sh` to keep them out of the user's own `scripts/` tree). Inside this framework's own source tree they live at `scripts/scrum/*.sh`; both invocation styles work because neither matches the guard's block patterns.

## Mapping

| Old (raw) | New (validated wrapper) |
|---|---|
| `jq '(.items[] | select(.id == "$PBI")).status = "in_progress"' .scrum/backlog.json > tmp && mv tmp .scrum/backlog.json` | `.scrum/scripts/update-backlog-status.sh "$PBI" in_progress` |
| Same pattern for `review`, `done`, `blocked`, etc. | `.scrum/scripts/update-backlog-status.sh "$PBI" {draft\|refined\|in_progress\|review\|done\|blocked}` |
| `jq '.items += [{id:"pbi-NNN",title:"...",status:"draft",...}] \| .next_pbi_id += 1' .scrum/backlog.json > tmp && mv ...` | `.scrum/scripts/add-backlog-item.sh --title <text> [--description <text>] [--ac <criterion>]... [--parent <pbi-id>] [--ux-change]` (allocates id from `next_pbi_id`, prints new pbi-id to stdout) |
| `jq '.status = "active"' .scrum/sprint.json > tmp && mv tmp .scrum/sprint.json` | `.scrum/scripts/update-sprint-status.sh active` (also: `planning`, `cross_review`, `sprint_review`, `complete`, `failed`) |
| `jq '.developers["dev-001-s1"].current_pbi = "pbi-007"' .scrum/sprint.json > tmp && mv ...` | `.scrum/scripts/set-sprint-developer.sh dev-001-s1 current_pbi pbi-007` (fields: `status`, `current_pbi`, `current_pbi_phase`) |
| `jq '.phase = "design"' .scrum/state.json > tmp && mv ...` | `.scrum/scripts/update-state-phase.sh design` |
| `jq '.messages += [{...}]' .scrum/communications.json > tmp && mv ...` | `.scrum/scripts/append-communication.sh --from <id> --to <id\|null> --kind <type> --content <text> [--role <role>] [--pbi <pbi-id>]` |
| `jq '.events += [{...}]' .scrum/dashboard.json > tmp && mv ...` | `.scrum/scripts/append-dashboard-event.sh --type <type> [--agent <id>] [--pbi <pbi-id>] [--file <path>] [--change-type <ct>] [--detail <text>] [--phase-from <p>] [--phase-to <p>]` |
| `update_state ".scrum/pbi/$PBI/" '.design_round = 1'` (PR #22 inline helper) | `.scrum/scripts/update-pbi-state.sh "$PBI" design_round 1` (variadic field/value pairs in one atomic write) |
| `printf '%s\t%s\t...\n' >> .scrum/pbi/$PBI/pipeline.log` | `.scrum/scripts/append-pbi-log.sh "$PBI" <phase> <round> <event> <detail>` |

`update-pbi-state.sh` accepts variadic field/value pairs:

```
.scrum/scripts/update-pbi-state.sh pbi-001 phase impl_ut design_status pass impl_round 1
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

The current wrapper set covers the pbi-pipeline migration and the four migrated skill SKILL files. The following raw writes are **not yet** covered and will be blocked by the `PreToolUse` hook at runtime until the listed follow-ups land:

1. **`skills/sprint-planning/SKILL.md` step 11.2** writes `items[].catalog_targets` via raw `jq`. Required follow-up:
   - Add `catalog_targets` (array of strings) to `docs/contracts/scrum-state/backlog.schema.json` under `items` (currently rejected by `additionalProperties: false`).
   - Ship a wrapper, e.g. `.scrum/scripts/set-backlog-item-field.sh <pbi-id> catalog_targets <json-array>` (or per-field setters).
2. **Sprint creation / init** (sprint-planning step 9) requires a fresh `.scrum/sprint.json`; no `init-sprint.sh` wrapper exists yet — the existing wrappers all assume the file is present (`E_FILE_MISSING` otherwise).
3. **Backlog item field updates** (sprint-planning step 10) — `items[].sprint_id`, `items[].implementer_id`, `items[].reviewer_id` have no wrapper. They need the same per-field setter as gap (1), or one setter per field.
4. **Append-only siblings** — `.scrum/sprint-history.json`, `.scrum/improvements.json`, `.scrum/test-results.json`, `.scrum/session-map.json` have no schema and no wrapper. Out of scope for this PR; defer until the MVP soaks.
5. **Read-side validation** — `dashboard/app.py` and the various hooks that read `.scrum/*.json` do not validate against the schemas. Defensive read-side patches (e.g. UnicodeDecodeError handling) stay; schema-driven validation is a future hardening pass.

Each of these has a `TODO(scrum-state-tools)` comment in the relevant file pointing back to this document. Until they land, sprint-planning step 11.2 (and likely 9 and 10) **will fail at runtime** when the hook fires.

## Worktree / merge governance wrappers (2026-05-04)

| Wrapper | Writes |
|---|---|
| `freeze-sprint-base.sh` | `sprint.base_sha`, `sprint.base_sha_captured_at` (once per Sprint) |
| `create-pbi-worktree.sh` | `pbi/<id>/state.json` `branch`, `worktree`, `base_sha`; creates git worktree + `.scrum` symlink |
| `commit-pbi.sh` | git commit on `pbi/<id>` branch + `pbi/<id>/state.json.head_sha` |
| `mark-pbi-ready-to-merge.sh` | `pbi/<id>/state.json` `phase=ready_to_merge`, `head_sha`, `paths_touched`, `ready_at`; backlog item `status=review` |
| `mark-pbi-merged.sh` | `pbi/<id>/state.json` `phase=merged`, `merged_sha`, `merged_at`, `merge_failure_count=0`; backlog item `merged_sha`, `merged_at` |
| `mark-pbi-merge-failure.sh` | `pbi/<id>/state.json` `phase ∈ merge_*`, `merge_failure`, `merge_failure_count++`; on 3rd consecutive failure: `phase=escalated`, `escalation_reason=stagnation`, backlog `status=blocked` |
| `cleanup-pbi-worktree.sh` | removes git worktree + `pbi/<id>` branch (post-merge) |
| `merge-pbi.sh` | orchestrator (calls mark-pbi-merged or mark-pbi-merge-failure + cleanup) |

### Backward compatibility (sprints in flight at upgrade time)

This change extends `cross-review` to require every Sprint PBI at
`pbi/<id>/state.json.phase ∈ {merged, escalated}`. PBIs from sprints
that completed under the old (pre-merge-governance) flow may sit at
`phase=complete` or `phase=review_complete` with no `branch` /
`worktree` / `base_sha` in `state.json`.

If you upgrade a project with sprints in flight, choose one of:

- (A) Let the in-flight sprint finish under the old flow. Skip
  `cross-review` precondition by manually advancing each PBI's
  `state.phase` to `merged` via
  `update-pbi-state.sh <pbi-id> phase merged`. Then run
  `cross-review` and `sprint-review` as usual. Future sprints use the
  new flow.
- (B) Drop the in-flight sprint and replan. New sprints follow the
  new flow from the start.

For new projects: no migration needed. The new flow is in effect from
Sprint 1.
