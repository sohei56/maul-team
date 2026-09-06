---
catalog_id: S-060
created_sprint: sprint-001
last_updated_sprint: sprint-001
related_pbis: []
frozen: false
revision_history:
  - sprint: sprint-001
    author: scrum-master
    date: "2026-08-09T00:00:00Z"
    summary: "Define reproducible Phase 2 measurement and comparison procedures"
    pbis: []
  - sprint: sprint-001
    author: scrum-master
    date: "2026-08-09T00:00:00Z"
    summary: "Record independent Phase 2 experiments and adoption gates"
    pbis: []
---

# Thin Scrum Master: Phase 2 handoff

Phase 2 runs one experiment and one change at a time. Keep the current behavior
as the control; do not bundle experiments.

## Reproducible experiment record

Copy this record for each run and complete it before either arm starts. An arm
is a cohort of whole Sprints. Use either the same declared integer number of
consecutive eligible Sprints in each arm, or two non-overlapping,
equal-duration date windows whose start and end timestamps are declared before
the run. Do not choose the boundary after seeing results. A Sprint belongs to
the arm in which it starts and is counted once. Declare an equal post-acceptance
follow-up duration for escaped-defect observation. Do not add a sample limit
that the experiment plan does not otherwise require.

Store the completed record, derived comparison, conclusion, and validation
output at `result_path`. Store the event ledger beside it as
`<result_path directory>/measurements.jsonl`; fixed Scrum artifacts remain the
source evidence linked by ledger entries.

```yaml
experiment_id: <stable-id>
experiment: <name>
hypothesis: <one falsifiable sentence>
control: <current behavior and version/revision>
single_variable: <the only behavior changed>
assignment_rule: <equal Sprint N or equal-duration window rule>
baseline: {sprint_n_or_dates: <N or inclusive start/exclusive end>, revision: <git SHA>, evidence_path: <path>}
treatment: {sprint_n_or_dates: <same N or equal-duration dates>, revision: <git SHA>, evidence_path: <path>}
escaped_defect_follow_up: <same duration after each Sprint acceptance>
metrics:
  - <all shared metrics below, with no post-run additions or removals>
result_path: .scrum/experiments/<experiment-id>/result.md
owner: <role/name>
start_date: YYYY-MM-DD
decision_date: YYYY-MM-DD
rollback: <trigger and exact restoration action>
decision_record: .scrum/po/decisions.json#<dec-id-or-pending>
```

If either arm does not reach its predeclared boundary, record `incomplete` and
extend or reject the run; do not compare unequal cohorts. The owner records
adopt, reject, extend, or roll back only after both windows and both follow-up
periods close, then links the decision record.

### Manual measurement ledger

Existing state does not retain uncapped agent-call history, complete prompts or
results, reopen attribution, or escaped-defect attribution. For the duration of
an experiment, append one JSON object per observed event to
`measurements.jsonl`. This ledger is manual experiment evidence, not a new
Scrum-state authority and not general tool telemetry. Do not record individual
tool events or bytes read by `Read`.

Every row has `observed_at` (ISO 8601), `arm` (`control` or `treatment`),
`sprint_id`, `event`, and `source_path`. Event-specific fields are:

| `event` | Required fields |
|---|---|
| `session_start` | `session_id`, `resume_bytes`, `sm_skill_count`, `source_revision` |
| `agent_call` | `call_id`, `caller`, `agent_role`, `prompt_path`, `prompt_bytes`, `purpose`, `additional_research` (boolean) |
| `agent_result` | `call_id`, `result_path`, `result_bytes`, `status` |
| `sprint_outcome` | `decision_id`, `decision` (`approve` or `reject`) |
| `sprint_reopen` | `accepted_decision_id`, `reason`, `attribution_evidence` |
| `escaped_defect` | `defect_id`, `severity` (`critical`, `high`, or `low`), `discovered_at`, `introduced_sprint_id`, `attribution_evidence` |

`source_path`, `prompt_path`, `result_path`, and `attribution_evidence` are
repository-relative paths with an optional JSON pointer or Markdown anchor.
Persist exact prompt and result bodies under the run directory before counting
them. `call_id` and `defect_id` are unique within the run. A call without a
result still gets an `agent_result` row with the returned error/cancellation
body and status. The hook-capped `.scrum/communications.json` and
`.scrum/dashboard.json` may corroborate rows but must not replace the ledger.

### Metric definitions

All byte measurements are UTF-8 byte counts of the exact string, excluding any
newline added only by a display command: `LC_ALL=C printf '%s' "$value" | wc
-c`. File bodies are counted with `LC_ALL=C wc -c < path`. “Per Sprint” means
divide the arm total by the declared number of Sprints in that arm, including a
Sprint with zero events.

1. **Resume-summary size.** Unit: bytes per SessionStart, reported as arm mean
   and arm total per Sprint. Cohort: every SessionStart for a cohort Sprint,
   from that Sprint's start through its follow-up close. Authoritative source:
   `hooks/session-context.sh` output at that start, specifically
   `.hookSpecificOutput.additionalContext`, captured in the `session_start`
   row. Procedure: run the deployed hook against the then-current `.scrum/`
   snapshot, extract with `jq -rj
   '.hookSpecificOutput.additionalContext'`, and count bytes. Mean =
   `sum(resume_bytes) / count(session_start)`; total per Sprint =
   `sum(resume_bytes) / cohort_sprints`.

2. **Scrum Master always-loaded skill count.** Unit: skills per SessionStart.
   Cohort: the same `session_start` rows as resume-summary size. Authoritative
   source: the `skills` array in the Scrum Master definition deployed from
   `agents/scrum-master.md` at `source_revision`; absent means zero. Exact
   query: extract that revision's YAML frontmatter, then `yq
   '.skills // [] | length'`. Arm value =
   `sum(sm_skill_count) / count(session_start)`. Validate each recorded value
   against its revision rather than against only the final worktree.

3. **Explorer invocations.** Unit: invocations per Sprint. Cohort: every
   `agent_call` made during a cohort Sprint or its follow-up whose `agent_role`
   is exactly `scrum-explorer`, including failed/cancelled calls. Authoritative
   source: `measurements.jsonl`, corroborated when available by
   `.scrum/communications.json`. Formula =
   `count(event == agent_call && agent_role == scrum-explorer) /
   cohort_sprints`.

4. **Operator invocations.** Unit: invocations per Sprint. Cohort: every
   `agent_call` made during a cohort Sprint or its follow-up whose `agent_role`
   is exactly `ceremony-operator`, including failed/cancelled calls.
   Authoritative source: `measurements.jsonl`, with the same optional
   communications corroboration. Formula =
   `count(event == agent_call && agent_role == ceremony-operator) /
   cohort_sprints`.

5. **Subagent prompt size.** Unit: UTF-8 bytes per agent call, reported as mean
   and total per Sprint. Cohort: every `agent_call` attributed to the cohort,
   regardless of role or status; a `SendMessage` to an already-running
   teammate is not a call. Authoritative source: each ledger `prompt_path` and
   `prompt_bytes`. Mean = `sum(prompt_bytes) / count(agent_call)`; total per
   Sprint = `sum(prompt_bytes) / cohort_sprints`.

6. **Subagent result size.** Unit: UTF-8 bytes per completed, failed, or
   cancelled agent call, reported as mean and total per Sprint. Cohort: the
   calls from metric 5, paired one-to-one by `call_id`. Authoritative source:
   each ledger `result_path` and `result_bytes`. Mean =
   `sum(result_bytes) / count(agent_call)`; total per Sprint =
   `sum(result_bytes) / cohort_sprints`. Missing results invalidate the run;
   they are not silently counted as zero.

7. **Additional research.** Unit: requests per Sprint. Cohort: calls from
   metric 5 for which the caller requested evidence beyond the first planned
   bounded investigation for the same ceremony decision or PBI. The caller
   sets `additional_research=true` at request time and states the repeated
   evidence need in `purpose`; ordinary implementation/review calls are false.
   Authoritative source: `measurements.jsonl`. Formula =
   `count(event == agent_call && additional_research == true) /
   cohort_sprints`. This records requests, not `Read` calls or bytes.

8. **Agent-call count.** Unit: calls per Sprint. Cohort: every new short-lived
   agent invocation initiated by the Scrum Master, Product Owner, or Developer
   during a cohort Sprint or its follow-up, including Explorer/operator calls
   and failed/cancelled calls. Continuing conversation through `SendMessage`
   is excluded. Authoritative source: unique `agent_call.call_id` values in
   `measurements.jsonl`. Formula = `count(distinct call_id) / cohort_sprints`.

9. **Acceptance rate.** Unit: percentage of Sprints. Cohort: every distinct
   cohort Sprint, evaluated at the arm close using its last
   `kind=sprint_acceptance` decision at or before close. Authoritative source:
   `.scrum/po/decisions.json`; ledger `sprint_outcome` rows copy the decision id
   for reconciliation. Numerator = cohort Sprints whose terminal decision is
   `approve`; denominator = cohort Sprints whose terminal decision is
   `approve` or `reject`; rate = `100 * numerator / denominator`. The
   denominator is Sprints, never PBIs, demos, UAT items, or acceptance
   criteria. Every declared cohort Sprint must have a terminal decision or the
   run is incomplete.

10. **Reopen rate.** Unit: percentage of accepted Sprints. Cohort: accepted
    cohort Sprints through their equal follow-up close. A Sprint is reopened
    once if, after its approving `sprint_acceptance`, its increment causes a
    workflow return to development/backlog for a defect or requested change;
    repeated cycles still count that Sprint once. Authoritative source:
    `sprint_reopen` ledger rows linked to `.scrum/state.json` transition
    evidence, the resulting `.scrum/backlog.json` item, and/or the PO decision.
    Numerator = distinct accepted cohort Sprints with at least one valid reopen
    row; denominator = accepted cohort Sprints; rate =
    `100 * numerator / denominator`. Zero accepted Sprints makes the rate
    undefined and the experiment cannot be adopted.

11. **Escaped defects.** Unit: distinct attributable defects per Sprint,
    reported both for all severities and for Critical/High combined. Cohort: a
    defect discovered after a cohort Sprint's approving
    `sprint_acceptance`, within its declared follow-up, whose causal change was
    introduced by that Sprint. Discovery Sprint does not determine the arm.
    Authoritative source: `escaped_defect` ledger rows linked to the defect PBI,
    `.scrum/po/decisions.json`, UAT/audit report, and commit or root-cause
    evidence. Prefer `audit_identity` as `defect_id`; otherwise assign one
    stable run-local defect identity and deduplicate the same root cause.
    Severity is the recorded finding severity, not backlog priority. Total rate
    = `count(distinct defect_id) / cohort_sprints`; Critical/High rate = the
    same query filtered to `severity in {critical, high}`. Attribution requires
    a path/commit and a one-sentence causal rationale in
    `attribution_evidence`; unknown attribution is reported separately and
    blocks adoption rather than being assigned to the more favorable arm.

### Aggregates and validation

`context` is an equal-weight, dimensionless index over eight arm-level burdens:
resume-summary total bytes/Sprint, always-loaded skill mean, Explorer
invocations/Sprint, operator invocations/Sprint, prompt bytes/Sprint, result
bytes/Sprint, additional-research requests/Sprint, and agent calls/Sprint. For
each component, control index is `1` and treatment index is
`treatment_value / control_value`; if both values are zero the component index
is `1`, and if only control is zero the treatment index is infinite. The arm's
`context` is the arithmetic mean of its eight component indexes. Thus context
falls by 20% exactly when treatment context is at most `0.80`, and increases by
no more than 10% exactly when it is at most `1.10`.

`quality` is the Pareto comparison of acceptance rate (higher is better),
reopen rate (lower), total escaped-defect rate (lower), and escaped
Critical/High rate (lower). It is **at least unchanged** only when no component
is worse; it **improves** only when no component is worse and at least one is
strictly better. Undefined or unattributed quality data blocks adoption. The
separate acceptance and Critical/High guards below are retained as explicit
safety gates even where this comparison is stricter.

Before deciding, the owner must:

1. Verify the record predates collection, the revisions differ only in the
   declared variable, arm boundaries are equal as declared, Sprints occur in
   only one arm, and follow-up durations match.
2. Parse every JSONL row, reject duplicate ids, require the fields above, pair
   every agent call/result, and confirm each event timestamp lies inside its
   Sprint or follow-up boundary.
3. Recompute every recorded byte count from its retained body and every skill
   count from the recorded revision; reconcile agent calls with available hook
   logs without treating capped logs as proof of absence.
4. Reconcile each cohort Sprint's terminal acceptance decision to
   `.scrum/po/decisions.json`, and trace every reopen and escaped defect to its
   linked state, backlog, PO, audit/UAT, and causal evidence.
5. Re-run all formulas from the ledger, record numerator, denominator, raw arm
   value, delta, context component indexes, and quality comparison in
   `result_path`; have a second reviewer reproduce the calculation before the
   adoption decision.

## Shared measurements and adoption gate

Measure every metric above. Do **not** measure Scrum Master `Read` bytes or all
tool events.

Adopt an experiment only when escaped Critical/High defects do not increase,
acceptance rate is not worse by more than 10 percentage points, and either:

- quality is at least unchanged while context falls by at least 20%; or
- quality improves while context increases by no more than 10%.

For these guards, compare the treatment Critical/High escaped-defect rate with
the control rate (`treatment <= control`) and calculate acceptance change as
`treatment percentage - control percentage` (`>= -10` percentage points).

## Experiment 1: risk-based PBI pipeline

Change only PBI risk routing. Introduce Low, Standard, and High risk; default to
Standard, and let High preserve the current pipeline. Promote risk after a major
finding, unclear acceptance criteria, or repeated failure. Never auto-demote.
Compare the shared measurements and apply the shared adoption gate.

## Experiment 2: integrated implementation review

Change only implementation/review integration. Integrate implementation, unit
testing, and integrity review. Add another reviewer or Codex only for High-risk
work, security/migration/public-contract changes, reviewer disagreement, a
Critical/High finding, or repeated same-cause failure. Compare the shared
measurements and apply the shared adoption gate.

## Experiment 3: tiered regression

Change only regression selection. After each merge, run affected tests plus the
mandatory smoke test. Escalate to the full regression suite when impact is
unknown, shared core/schema/migration code changes, the PBI is High risk, or a
test fails. Always run full regression at Sprint Review and before release.
Compare the shared measurements and apply the shared adoption gate.

## Experiment 4: physical archive layout v2

Change only artifact layout, and only after fixed-path readers incrementally use
a resolver. Then use layout v2 for new projects only, split into current,
archive, and runtime areas. Seal completed Sprints only; never archive an active
or escalated PBI. Do not auto-migrate existing projects. Compare the shared
measurements and apply the shared adoption gate.

## Experiment 5: Context Gateway

Evaluate a Context Gateway only if a single resume summary plus Explorer still
repeatedly lacks necessary information. Add one extra View at a time (for
example planning or merge), measuring it independently before adding another.
Compare the shared measurements and apply the shared adoption gate.
