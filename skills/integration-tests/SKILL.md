---
name: integration-tests
description: >
  Integration Tests — design-driven, systematic verification for the
  Integration Sprint. Derives boundary-value, flow-branch, and
  pattern-branch test cases from the enabled design specs, builds stubs
  for non-reproducible external interfaces, automates API and UI tests
  as committed project assets, and records results to
  .scrum/test-results.json. Runs before UAT & Release.
disable-model-invocation: false
---

## Inputs

- state.json → phase: "retrospective" (entered via
  `sprint_continuation: integration_sprint`) or already
  "integration_sprint" on re-entry.
- `docs/design/catalog-config.json` — `enabled` array of spec IDs
  (SSOT for which specs are in scope).
- `docs/design/specs/**` — enabled spec files. Per
  `docs/design/catalog.md`, each lives at
  `docs/design/specs/{category}/{id}-{slug}.md`.
- `docs/requirements.md` — context for resolving spec terms
  (read-only).
- `.scrum/sprint.json.id` — current sprint id, used in output paths.
- Project source code + existing test suites.

## Outputs

- `.scrum/integration-tests/<sprint-id>/test-cases.md` — the test-case
  matrix plus a spec ⇄ case traceability table (see
  [references/test-case-design.md](references/test-case-design.md)).
- `tests/integration/**` — API integration tests in the project's
  test language, committed to the target project (persistent asset).
- `tests/e2e/**` — Playwright UI tests, committed to the target
  project (persistent asset).
- `tests/stubs/**` — external-interface stubs, committed to the target
  project. See
  [references/stub-construction.md](references/stub-construction.md).
- `.scrum/test-results.json` — TestCategories appended via
  `.scrum/scripts/record-test-result.sh`
  (`integration_api` / `integration_ui` / `design_coverage` /
  `manual_probe`); `overall_status` recomputed by the wrapper.
- Defect PBIs in `.scrum/backlog.json` when the quality gate fails.
- A completion report to the SM via `SendMessage`.

## Preconditions

- ≥1 Development Sprint completed (tests and running system exist).
- requirements.md and the enabled design specs exist.
- Testing Developer teammate(s) available to run the pipeline.

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, the human user is not the
PO seat — the `product-owner` teammate is. The ceremony shape is
unchanged; only the destination of PO-approval prompts is re-targeted.
Apply the following overrides to the Steps below; everything not in
this table runs verbatim. The decision to enter the Integration Sprint
is already made upstream by the `retrospective` `sprint_continuation`
decision — this skill has no start gate of its own.

| Step | Override (po_mode=agent) |
|------|--------------------------|
| 7. Quality gate (`failed`) | Replace "ask user for additional issues" with one structured PO pass: `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[high,medium,low,reject] recommendation=<...>` carrying the full failure list (smoke + integration + design-coverage). PO returns a priority for each failure in a single reply. No human-input wait, no "any other issues" loop. |

The "user confirms" / "ask the user" phrases in the Steps below are
mode-agnostic: under `po_mode=agent` they resolve to
`PO_DECISION_REQUEST` per the table above, not to human prompts. SM
never blocks on `read` from stdin in this mode. Informational lines
("report to the user") are observation-only — emit the summary, do not
wait for a reply.

## Steps

1. **Enter the phase.** state.json → phase: "integration_sprint":
   ```bash
   .scrum/scripts/update-state-phase.sh integration_sprint
   ```
   (No-op when already there on re-entry.)

   **Codebase-audit pre-flight gate (mandatory).** Before any test
   derivation, a whole-repo `codebase-audit` must have run and be
   gate-clean for the current rollover. Check for
   `.scrum/reviews/codebase-audit-s{N}.md` (`N` = numeric sprint number
   from `sprint.json.id`); if it is missing or carries open
   Critical/High findings, run the `codebase-audit` skill now and let
   it resolve. If that audit trips its gate it creates defect PBIs and
   sets the phase back to `backlog_created` — **stop here**; the
   Integration Sprint resumes after the defect-fix loop. Proceed to
   Step 2 only once the audit is gate-clean. Rationale: per-PBI and
   Sprint-diff review cannot see whole-repo defects (dead code, silent
   I/O failures, cross-spec conflicts, cross-PBI duplication); catching
   them here is far cheaper than during integration testing.

2. **Spawn the testing Developer teammate(s)** via the
   `spawn-teammates` skill (1–2 for testing). The Developer(s) run
   Steps 3–6.

3. **Delegate the `smoke-test` skill** and **wait for completion** (do
   NOT proceed early). This confirms the existing test assets still
   pass (regression) and records the base categories in
   `.scrum/test-results.json`. `passed_with_skips` is not a failure —
   continue.

4. **Design the test cases** — follow
   [references/test-case-design.md](references/test-case-design.md).
   Derive a test-case matrix from **every enabled spec** applying the
   per-category derivation rules (boundary values + equivalence
   partitioning for interfaces, decision tables for business rules,
   state-transition coverage for workflows, screen-flow + form
   boundaries + journeys for UI, stub scenarios for external
   integration), and write it to
   `.scrum/integration-tests/<sprint-id>/test-cases.md` with a
   spec ⇄ case traceability table. The uncovered list MUST be empty
   or carry an explicit per-item waiver rationale.

5. **Build stubs** for non-reproducible external interfaces — follow
   [references/stub-construction.md](references/stub-construction.md).
   Enumerate the external interfaces that cannot be exercised locally,
   map each from its S-022 contract, and implement stubs under
   `tests/stubs/`. Connection switching is by environment variable —
   never embed a stub branch in product code.

6. **Automate and execute** — follow
   [references/test-automation.md](references/test-automation.md).
   Implement API cases in `tests/integration/` (project test library)
   and UI cases in `tests/e2e/` (Playwright code); run them. Only
   cases that cannot be automated fall back to Claude-driven probes
   (Playwright MCP / Chrome DevTools MCP with logged evidence), then to
   a human-manual checklist. Record verdicts through
   `.scrum/scripts/record-test-result.sh` under categories
   `integration_api` / `integration_ui` / `design_coverage` /
   `manual_probe`, and report the automation rate. Once the tests are
   green, commit the test assets (`tests/integration/`, `tests/e2e/`,
   `tests/stubs/`) to the target project's main worktree — the sole
   sanctioned path is
   `.scrum/scripts/commit-integration-tests.sh "<message>"`, which
   refuses to commit anything outside the test-asset set. When a test
   runner configuration file (e.g. `pytest.ini`, `playwright.config.ts`)
   must be committed alongside the assets, pass it via `--allow <path>`
   and state the path and reason in the Step 7 SM report.

7. **Quality gate + SM report** (combined `overall_status` across smoke
   + integration + design-coverage categories):
   - **passed** / **passed_with_skips** → report to the SM that
     integration tests are green. The SM transitions the phase to
     `uat_release` and launches the `uat-release` skill. **This skill
     does not transition to `uat_release` itself** — that is
     `uat-release` Step 1. Note skipped categories, `not_testable`
     items, and the human-manual checklist in the report so they carry
     into UAT.
   - **failed** → review errors → self-review related code → present
     all failures → ask the user for any additional issues → create
     one PBI per confirmed failure (acceptance_criteria: expected vs
     actual, priority by severity) → transition to the development
     loop:
     ```bash
     .scrum/scripts/update-state-phase.sh backlog_created
     ```
     After the fix Sprint, re-enter integration tests.
   - **No fix without an assigned PBI — non-negotiable.**
   - `design_coverage` failures (including `missing` spec'd functions)
     follow the same failed path. `missing` items become
     implementation PBIs referencing the spec anchor recorded in the
     test-case matrix.
   - **po_mode=agent**: replace "ask the user for additional issues"
     with one `kind=defect_triage` `PO_DECISION_REQUEST` carrying the
     full failure list; the PO returns priorities in a single reply
     (no per-failure round-trip).

Ref: FR-013

## Strict Rules

- The tester **never** fixes defects discovered during this skill.
  Defects route through SM → PBI per `FR-010`. **No fix without an
  assigned PBI.**
- The tester **never** edits product source code or design specs while
  this skill runs.
- Functions not in an enabled spec are out of scope — no
  spec-invention. Catalog governance (`docs/design/catalog.md`)
  applies.
- A spec assertion is **never** lowered to make a test pass. Ambiguous
  assertions become `not_testable` with a rationale.
- A `missing` item **never** gets reclassified as `not_testable` to
  dodge the failed-count. `not_testable` means "cannot express the
  check as a runnable integration scenario", not "no implementation
  yet".
- Stubs are a **mapping of the S-022 contract only** — never invent
  external behavior the spec does not state.
- **Never silently drop** an uncovered branch or boundary. Every
  uncovered item is either covered by a case or waived with a
  rationale in the traceability table.

## Exit Criteria

- `.scrum/integration-tests/<sprint-id>/test-cases.md` exists with a
  complete spec ⇄ case traceability table (uncovered list empty or
  explicitly waived).
- `.scrum/test-results.json` has `overall_status` set, with
  `integration_api`, `integration_ui`, and `design_coverage`
  categories recorded (executed or skipped-with-reason).
- Committed automation assets exist under `tests/integration/` and/or
  `tests/e2e/` for the automated cases; stubs under `tests/stubs/` for
  any external interface.
- Automation rate reported to the SM.
- passed → SM notified to launch `uat-release`; OR failed → defect PBIs
  created and phase returned to `backlog_created`.
