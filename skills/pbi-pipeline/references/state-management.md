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

The 7 SM-managed status values (see [docs/data-model.md § State Transitions: status](../../../docs/data-model.md#state-transitions-status-12-value-enum-actor-split)) MUST NOT be written by this skill.

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
`escalated`): canonical value list in
[docs/data-model.md § PbiPipelineState](../../../docs/data-model.md#entity-pbipipelinestate).

The merge-* values are written by SM-side `mark-pbi-merge-failure.sh`,
not by this skill. `reviewer_unavailable` and `stale_review_snapshot`
are written by the impl/UT review path when the reviewer sub-agent
cannot run or when a review snapshot has been invalidated by a
subsequent commit.

## Initialization

```bash
.scrum/scripts/init-pbi-state.sh "$PBI_ID"
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_design
```

`init-pbi-state.sh` creates `.scrum/pbi/<pbi-id>/` with the standard
`design`, `impl`, `ut`, `metrics`, `feedback` subdirectories and seeds
`state.json` with all required fields (rounds at 0, statuses at
`pending`, `escalation_reason: null`). It is idempotent — re-running on
an existing valid state is a no-op.

## Atomic update helpers

ALWAYS update PBI state via the validated wrapper scripts (never raw jq):

```bash
# Internal mechanics (per-stage *_status flags, design_round, escalation_reason)
.scrum/scripts/update-pbi-state.sh "$PBI_ID" design_round 1 design_status in_review

# Stage transition (always via backlog status SSOT)
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl

# Escalation: write reason to internal state, then flip backlog status
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason stagnation
.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
```

### `impl_round` is owned by `begin-impl-round.sh`

The impl-Round counter has a dedicated wrapper that owns BOTH the
arithmetic and the backlog-status transition:

```bash
n=$(.scrum/scripts/begin-impl-round.sh "$PBI_ID")
```

- Atomically increments `impl_round`, resets `impl_status` and
  `ut_status` to `pending`, and (idempotently) sets backlog status
  to `in_progress_impl`.
- Idempotent on Developer respawn: if `impl_status == "pending"` and
  `impl_round > 0`, it returns the current value without mutating.
- Refuses if the backlog pre-state isn't one of
  `{in_progress_design, in_progress_pbi_review, in_progress_ut_run,
  in_progress_impl}`.

Within the impl / PBI-review / UT-run cycle, conductors MUST NOT write
`impl_round` via `update-pbi-state.sh` — `begin-impl-round.sh` is the
sole incrementer. The one sanctioned exception is the Design-success
reset to 0: `design-stage.md` Step 3 sets `design_status pass
impl_round 0` as it hands off to impl, seeding the counter before the
first `begin-impl-round.sh` call. Owning the counter in one place
removes the failure mode where an agent resets `n` to 1 after a Cross
Review revert (Round counter displayed in the dashboard regressed to 1
even though the PBI had already completed Rounds 1..N internally).

`update-pbi-state.sh`:
- validates against `docs/contracts/scrum-state/pbi-state.schema.json`,
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

One line per stage event, append-only. The first column is a coarse
stage identifier drawn from the fixed set
`init | design | pbi_review | ut_run | complete | escalated` (enforced
by `append-pbi-log.sh`); it is NOT the `in_progress_*` backlog-status
segment. Impl-round events are logged under `pbi_review` or `ut_run`:

```text
<ISO8601>\t<stage>\t<round>\t<event>\t<detail>
```

Examples:

```text
2026-05-02T12:00:00+09:00	init	0	created	.scrum/pbi/pbi-001/
2026-05-02T12:01:00+09:00	design	1	spawn	pbi-designer
2026-05-02T12:05:00+09:00	design	1	spawn	codex-design-reviewer
2026-05-02T12:06:00+09:00	design	1	gate	success → impl
2026-05-02T12:06:30+09:00	pbi_review	1	spawn	pbi-implementer + pbi-ut-author
2026-05-02T12:20:00+09:00	ut_run	1	measure	coverage c0=87 c1=72
2026-05-02T12:25:00+09:00	pbi_review	1	gate	fail → impl round 2 (test_failures=2)
```

Use the `append-pbi-log.sh` wrapper instead of raw `printf >>`:

```bash
.scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$ROUND" "$EVENT" "$DETAIL"
```

## Sprint-level state side-effects

When a PBI starts pipeline:
- Set `.scrum/sprint.json.developers[<dev>].current_pbi = "<pbi_id>"`
- The Developer's current stage is read directly from
  `backlog.json.items[].status`; no separate sprint-level field
  duplicates it. Active pipelines are derived from backlog by filtering
  items whose status starts with `in_progress_`.

When a PBI completes (handed off to SM via `in_progress_merge`) or
escalates:
- Backlog status was already written by the Developer
  (`in_progress_merge` via `mark-pbi-ready-to-merge.sh`, or
  `escalated` via `update-backlog-status.sh`).
- No additional sprint-level cleanup is needed — readers re-derive the
  active set from `backlog.json` on each query.

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
