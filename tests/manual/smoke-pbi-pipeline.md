# PBI Pipeline Manual Smoke Test

End-to-end smoke for the new pipeline using a real Claude Code session.
Used until automated sub-agent invocation is mockable.

## Prerequisites

- Codex CLI installed (`which codex` non-empty), OR be ready to verify
  Claude fallback path
- A target project with `claude-scrum-team` installed
  (`scripts/setup-user.sh`)
- A simple PBI in `.scrum/backlog.json`, e.g. "add a function `add(a,b)`
  in `src/calc.py` that returns `a+b`"
- `.scrum/config.json` configured for Python:

  ```json
  {"test_runner":{"command":"pytest","args":["-q"]},
   "coverage_tool":{"command":"coverage",
                    "run_args":["run","--branch","--source=src","-m","pytest"],
                    "report_args":["json","-o"],
                    "supports_branch":true},
   "pragma_pattern":"pragma: no cover",
   "path_guard":{"impl_globs":["src/**"],"test_globs":["tests/**"]}}
  ```

## Procedure

1. **Launch the Scrum team**

   ```bash
   sh scrum-start.sh
   ```

   Confirm Developer agent spawns and is assigned the test PBI.

2. **Verify Developer initializes PBI directory**

   In a separate terminal:

   ```bash
   ls .scrum/pbi/
   ```

   Expected: directory matching the PBI id appears with subdirs
   `design/ impl/ ut/ metrics/ feedback/`.

3. **Verify design Round 1**

   Wait until `cat .scrum/backlog.json | jq -r '.items[] | select(.id=="<pbi-id>") | .status'`
   returns `"in_progress_design"` then `"in_progress_impl"`.

   Inspect:
   - `.scrum/pbi/<pbi-id>/design/design.md` — should contain all 6
     required sections, no implementation code.
   - `.scrum/pbi/<pbi-id>/design/review-r1.md` — verdict line present.

4. **Verify impl + PBI review + UT run Round 1**

   Wait for the status to advance through `in_progress_pbi_review` →
   `in_progress_ut_run` → `in_progress_merge`. Inspect:
   - `src/calc.py` should contain `def add(a, b): return a + b`
   - `tests/test_calc.py` should contain pytest tests
   - `.scrum/pbi/<pbi-id>/metrics/coverage-r1.json` should show C0/C1
     near 100%
   - `.scrum/pbi/<pbi-id>/impl/review-r1.md` and `ut/review-r1.md`
     should both have `**Verdict: PASS**`

5. **Verify cross_review and completion**

   After per-PBI merge, status becomes `awaiting_cross_review`. SM
   runs the `cross-review` skill at Sprint end, advancing status to
   `cross_review` and finally `done`. Verify:
   - `backlog.json` PBI status `done`
   - `.scrum/pbi/<pbi-id>/pipeline.log` records the round counts and final coverage

6. **Path-guard violation check**

   In Claude Code logs, search for `[path-guard] BLOCKED`. Should find
   zero entries during a healthy run. (If non-zero, that indicates a
   sub-agent attempted forbidden path access — log it for follow-up.)

7. **TUI verification**

   In another terminal:

   ```bash
   python3 dashboard/app.py
   ```

   Confirm "PBI Pipeline" pane renders the active PBI with status /
   round / sub-agents.

## Failure Recovery

- If gate evaluation hangs: `cat .scrum/pbi/<pbi-id>/pipeline.log`
- If escalation triggered: `cat .scrum/pbi/<pbi-id>/escalation-resolution.md`
- If Codex unavailable: log will mention `[Fallback: Claude review]`

## Pass Criteria

- All 7 procedure steps complete with expected outcomes
- No path-guard violations
- pipeline.log shows status transitions: init → in_progress_design → in_progress_impl → in_progress_pbi_review → in_progress_ut_run → in_progress_merge → awaiting_cross_review → cross_review → done
