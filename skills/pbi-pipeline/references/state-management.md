# State Management Reference

How the Developer (conductor) manages PBI internal state.

## SSOT for stage position

The Developer's stage position is the PBI's
`backlog.json.items[].status` (a 12-value flat enum). The internal
`pbi-state.json` holds round counters and per-stage `*_status`
flags only. There is no `phase` field; status is the sole SSOT.

| Stage | Backlog status |
|---|---|
| Design | `in_progress_design` |
| Impl (writing source + tests) | `in_progress_impl` |
| PBI Review (codex-impl + codex-ut review) | `in_progress_pbi_review` |
| UT Run (test execution + coverage gate) | `in_progress_ut_run` |
| Ready-to-merge handoff | `in_progress_merge` |
| Termination-gate escalation | `escalated` |

Backlog statuses outside that set (`draft / refined / blocked /
awaiting_cross_review / cross_review / done`) are SM-managed and
MUST NOT be written by this skill.

## Schema: `.scrum/pbi/<pbi-id>/state.json`

```json
{
  "pbi_id": "pbi-001",
  "design_round": 0,
  "impl_round": 0,
  "design_status": "pending | in_review | fail | pass",
  "impl_status": "pending | in_review | fail | pass",
  "ut_status": "pending | in_review | fail | pass",
  "coverage_status": "pending | fail | pass",
  "escalation_reason": null,
  "started_at": "2026-05-02T12:00:00+09:00",
  "updated_at": "2026-05-02T12:00:00+09:00"
}
```

`escalation_reason` enum (only set when backlog status is
`escalated`):

```text
stagnation | divergence | max_rounds | budget_exhausted |
requirements_unclear | coverage_tool_error | coverage_tool_unavailable |
catalog_lock_timeout |
merge_conflict | merge_artifact_missing
```

The merge-* values are written by SM-side `mark-pbi-merge-failure.sh`,
not by this skill.

## Initialization

```bash
PBI_DIR=".scrum/pbi/${PBI_ID}"
mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}
NOW="$(date -Iseconds)"
jq -n --arg id "$PBI_ID" --arg now "$NOW" '{
  pbi_id: $id,
  design_round: 0, impl_round: 0,
  design_status: "pending", impl_status: "pending",
  ut_status: "pending", coverage_status: "pending",
  escalation_reason: null,
  started_at: $now, updated_at: $now
}' > "$PBI_DIR/state.json"

.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_design
```

## Atomic update helpers

ALWAYS update PBI state via the validated wrapper scripts (never raw jq):

```bash
# Internal mechanics (rounds + per-stage *_status flags)
.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_round 1 design_status in_review

# Stage transition (always via backlog status SSOT)
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl

# Escalation: write reason to internal state, then flip backlog status
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason stagnation
.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
```

`update-pbi-state.sh`:
- validates against `docs/contracts/scrum-state/pbi-state.schema.json`
  (no `phase` field accepted),
- takes a per-file `mkdir` lock for race safety,
- atomically writes via `tmp + mv`,
- auto-stamps `.updated_at = now`.

Variadic field/value pairs are applied as a single transaction.
Unknown fields or out-of-enum values are rejected with
`E_INVALID_ARG` (exit 64).

```bash
# Multiple internal fields atomically
.scrum/scripts/update-pbi-state.sh "$PBI_ID" \
  impl_round 1 \
  design_status pass

# Clear escalation_reason
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason null
```

## pipeline.log format

One line per stage event, append-only. The first column is the stage
identifier (matches the `in_progress_*` status segment, plus `init`
for setup events):

```text
<ISO8601>\t<stage>\t<round>\t<event>\t<detail>
```

Examples:

```text
2026-05-02T12:00:00+09:00	init	0	created	.scrum/pbi/pbi-001/
2026-05-02T12:01:00+09:00	design	1	spawn	pbi-designer
2026-05-02T12:05:00+09:00	design	1	spawn	codex-design-reviewer
2026-05-02T12:06:00+09:00	design	1	gate	success → impl
2026-05-02T12:06:30+09:00	impl	1	spawn	pbi-implementer + pbi-ut-author
2026-05-02T12:20:00+09:00	ut_run	1	measure	coverage c0=87 c1=72
2026-05-02T12:25:00+09:00	pbi_review	1	gate	fail → impl round 2 (test_failures=2)
```

Use the `append-pbi-log.sh` wrapper instead of raw `printf >>`:

```bash
.scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$ROUND" "$EVENT" "$DETAIL"
```

## Sprint-level state side-effects

When a PBI starts pipeline:
- Append PBI id to `.scrum/state.json.active_pbi_pipelines[]`
- Set `.scrum/sprint.json.developers[<dev>].current_pbi = "<pbi_id>"`
- The Developer's current stage is read directly from
  `backlog.json.items[].status`; no separate sprint-level field
  duplicates it.

When a PBI completes (handed off to SM via `in_progress_merge`) or
escalates:
- Remove from `active_pbi_pipelines[]`
- Backlog status was already written by the Developer
  (`in_progress_merge` via `mark-pbi-ready-to-merge.sh`, or
  `escalated` via `update-backlog-status.sh`).

## New fields (worktree / merge governance)

- `branch`, `worktree`, `base_sha` — written by `create-pbi-worktree.sh`
  at Sprint start
- `head_sha` — updated each round by `commit-pbi.sh`
- `paths_touched`, `ready_at` — written by `mark-pbi-ready-to-merge.sh`
- `merged_sha`, `merged_at` — written by `mark-pbi-merged.sh`
  (SM-side; transitions backlog status to `awaiting_cross_review`)
- `merge_failure`, `merge_failure_count` — written by
  `mark-pbi-merge-failure.sh` (SM-side; transitions backlog status to
  `escalated`)
