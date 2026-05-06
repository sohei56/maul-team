# State Management Reference

How the Developer (conductor) manages PBI internal state.

## Schema: `.scrum/pbi/<pbi-id>/state.json`

```json
{
  "pbi_id": "pbi-001",
  "phase": "design | impl_ut | complete | escalated",
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

`escalation_reason` enum (only set when `phase == escalated`):

```text
stagnation | divergence | max_rounds | budget_exhausted |
requirements_unclear | coverage_tool_error | coverage_tool_unavailable |
catalog_lock_timeout
```

## Initialization

```bash
PBI_DIR=".scrum/pbi/${PBI_ID}"
mkdir -p "$PBI_DIR"/{design,impl,ut,metrics,feedback}
NOW="$(date -Iseconds)"
jq -n --arg id "$PBI_ID" --arg now "$NOW" '{
  pbi_id: $id, phase: "design",
  design_round: 0, impl_round: 0,
  design_status: "pending", impl_status: "pending",
  ut_status: "pending", coverage_status: "pending",
  escalation_reason: null,
  started_at: $now, updated_at: $now
}' > "$PBI_DIR/state.json"
```

## Atomic update helper

ALWAYS update PBI state via the validated wrapper script (never raw jq):

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_round 1 design_status in_review
.scrum/scripts/update-pbi-state.sh "$PBI_ID" phase complete
.scrum/scripts/update-pbi-state.sh "$PBI_ID" phase escalated escalation_reason stagnation
```

The wrapper:
- validates against `docs/contracts/scrum-state/pbi-state.schema.json`,
- takes a per-file `mkdir` lock for race safety,
- atomically writes via `tmp + mv`,
- auto-stamps `.updated_at = now`.

Variadic field/value pairs are applied as a single transaction. Unknown fields or out-of-enum values are rejected with `E_INVALID_ARG` (exit 64).

```bash
# Multiple fields atomically
.scrum/scripts/update-pbi-state.sh "$PBI_ID" \
  phase impl_ut \
  impl_round 1 \
  design_status pass

# Clear escalation_reason
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason null
```

## pipeline.log format

One line per phase event, append-only:

```text
<ISO8601>\t<phase>\t<round>\t<event>\t<detail>
```

Examples:

```text
2026-05-02T12:00:00+09:00	init	0	created	.scrum/pbi/pbi-001/
2026-05-02T12:01:00+09:00	design	1	spawn	pbi-designer
2026-05-02T12:05:00+09:00	design	1	spawn	codex-design-reviewer
2026-05-02T12:06:00+09:00	design	1	gate	success → impl_ut
2026-05-02T12:06:30+09:00	impl_ut	1	spawn	pbi-implementer + pbi-ut-author
2026-05-02T12:20:00+09:00	impl_ut	1	measure	coverage c0=87 c1=72
2026-05-02T12:25:00+09:00	impl_ut	1	gate	fail → round 2 (test_failures=2)
```

For the line-formatted pipeline log, use the `append-pbi-log.sh` wrapper instead of raw `printf >>`:

```bash
.scrum/scripts/append-pbi-log.sh "$PBI_ID" "$PHASE" "$ROUND" "$EVENT" "$DETAIL"
```

## Sprint-level state side-effects

When a PBI starts pipeline:
- Append PBI id to `.scrum/state.json.active_pbi_pipelines[]`
- Set `.scrum/sprint.json.developers[<dev>].current_pbi = "<pbi_id>"`
- Set `.scrum/sprint.json.developers[<dev>].current_pbi_phase` to track

When a PBI completes or escalates:
- Remove from `active_pbi_pipelines[]`
- backlog.json items[].status is auto-projected by `update-pbi-state.sh`
  (complete → `review`; escalated → `blocked`). Do NOT call
  `update-backlog-status.sh` directly — it rejects post-pipeline statuses.
- Add `pipeline_summary` to backlog.json item (rounds, final coverage)
  via a separate jq invocation (status is not part of the summary write).

## New fields (worktree / merge governance)

- `branch`, `worktree`, `base_sha` — written by `create-pbi-worktree.sh`
  at Sprint start
- `head_sha` — updated each round by `commit-pbi.sh`
- `paths_touched`, `ready_at` — written by `mark-pbi-ready-to-merge.sh`
- `merged_sha`, `merged_at` — written by `mark-pbi-merged.sh`
- `merge_failure`, `merge_failure_count` — written by
  `mark-pbi-merge-failure.sh`

## Phase → status projection (extended)

| state.phase | items[].status |
|---|---|
| design / impl_ut | in_progress |
| complete | review |
| ready_to_merge | review |
| merged | review |
| merge_conflict / merge_artifact_missing / merge_regression | review |
| escalated | blocked |
| review_complete | done |
