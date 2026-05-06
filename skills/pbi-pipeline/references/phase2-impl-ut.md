# Impl + PBI Review + UT Run Reference

Per-Round flow for the post-design stages (max 5 Rounds). Each Round
walks three backlog statuses:

```
in_progress_impl → in_progress_pbi_review → in_progress_ut_run
       ↑                                          │
       └────────── FAIL feedback ─────────────────┘
```

A round starts in `in_progress_impl`, advances to
`in_progress_pbi_review` once impl + UT code is committed, and to
`in_progress_ut_run` only after both reviewers PASS. A FAIL at either
review or at coverage measurement falls back to `in_progress_impl` for
the next round (or escalates via the termination gate).

## Round n procedure

### Step 1: Parallel spawn (pbi-implementer + pbi-ut-author)

Backlog status is `in_progress_impl`. Issue both Agent calls in a
single message (Claude Code parallel execution). Wait for both to
return.

```text
Agent(subagent_type="pbi-implementer", prompt=<from sub-agent-prompts.md § pbi-implementer>)
Agent(subagent_type="pbi-ut-author", prompt=<from sub-agent-prompts.md § pbi-ut-author>)
```

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" impl_round "$n" impl_status pending ut_status pending
# Status remains in_progress_impl while sources/tests are being written.
```

### Step 2: Move to PBI Review

Once both sub-agents have produced source + tests for Round n, advance
the status:

```bash
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_pbi_review
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" start —
```

Then spawn the two reviewers in parallel:

```text
Agent(subagent_type="codex-impl-reviewer", prompt=<from sub-agent-prompts.md>)
Agent(subagent_type="codex-ut-reviewer", prompt=<from sub-agent-prompts.md>)
```

Read review-r{n}.md from each, parse verdicts and findings.

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" impl_status in_review ut_status in_review
```

#### PBI Review FAIL branch

If either reviewer verdict is FAIL (and the termination gate does NOT
fire), build feedback for the next impl round and revert status:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" impl_status fail
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" gate "fail → in_progress_impl round $((n+1))"
# Recurse with n+1; see "Build feedback for next round" below.
```

### Step 3: UT Run (test execution + coverage measurement)

When both reviewers PASS, advance to UT Run:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" impl_status pass ut_status pass
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_ut_run
.scrum/scripts/append-pbi-log.sh "$PBI_ID" ut_run "$n" start —
```

See `coverage-gate.md` for the full procedure. Summary:

```bash
# Read .scrum/config.json (apply PBI override if design.md has a
# `yaml runtime-override` fence). Run test_runner.coverage_tool.command
# with merged args. Normalize output → coverage-r{n}.json,
# test-results-r{n}.json. Run pragma audit → pragma-audit-r{n}.json.
```

Tool-launch failure → escalate (`coverage_tool_error`).
Tool not installed → escalate (`coverage_tool_unavailable`).

### Step 4: Aggregate Pass criteria

Pass evaluation logic (see `coverage-gate.md` § Pass criteria):

```text
ALL of:
  test_results.totals.failed == 0
  test_results.totals.exec_errors == 0
  test_results.totals.uncaught_exceptions == 0
  coverage.totals.c0.percent >= c0_threshold (default 100.0)
  if c1.supported: coverage.totals.c1.percent >= c1_threshold (default 100.0)
  no pragma exclusion has reason_source == "missing"
  impl-reviewer.verdict == PASS  (already true to reach this stage)
  ut-reviewer.verdict == PASS    (already true to reach this stage)
```

#### Success branch (hand off to SM)

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" coverage_status pass
write_summary "$PBI_DIR/impl/summary.md"
write_summary "$PBI_DIR/ut/summary.md"
.scrum/scripts/mark-pbi-ready-to-merge.sh "$PBI_ID"
# mark-pbi-ready-to-merge.sh sets head_sha / paths_touched / ready_at
# and sets backlog.json items[].status = "in_progress_merge".
.scrum/scripts/append-pbi-log.sh "$PBI_ID" ut_run "$n" gate "success → in_progress_merge"
# Then: notify SM (PBI_READY_TO_MERGE).
```

#### UT Run FAIL (test/coverage failure)

If Pass criteria fail at UT Run (and the termination gate does NOT
fire), revert to impl for the next round:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" coverage_status fail ut_status fail
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
.scrum/scripts/append-pbi-log.sh "$PBI_ID" ut_run "$n" gate "fail → in_progress_impl round $((n+1))"
# Recurse with n+1; see "Build feedback for next round".
```

#### Termination gate (Stagnation / Divergence / Hard cap)

See `termination-gates.md`. On any escalate gate:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason "<reason>"
.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
.scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" gate "escalate → <reason>"
notify_sm_escalation "$PBI_ID" "<reason>"
```

`$STAGE` is `pbi_review` or `ut_run` depending on where the gate
fired.

### Build feedback for next round

See `feedback-routing.md`. Generate:

- `feedback/impl-r{n+1}.md` (impl-reviewer findings + test failures
  framed for impl)
- `feedback/ut-r{n+1}.md` (ut-reviewer findings + test failures framed
  for UT + coverage gaps + pragma issues)
