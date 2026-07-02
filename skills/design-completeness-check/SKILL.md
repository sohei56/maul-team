---
name: design-completeness-check
description: >
  Design-doc functional completeness verification at integration-test
  granularity for the Integration Sprint. Derives a functional inventory
  from the enabled design specs, verifies every item against the running
  integrated system, and appends a `design_completeness` TestCategory to
  `.scrum/test-results.json` so the existing quality and release gates
  pick the result up unchanged. Executed by a testing Developer teammate.
disable-model-invocation: false
---

## Inputs

- `docs/design/catalog-config.json` — `enabled` array of spec IDs (SSOT
  for which specs are in scope).
- `docs/design/specs/**` — enabled spec files. Per
  `docs/design/catalog.md`, each lives at
  `docs/design/specs/{category}/{id}-{slug}.md`.
- `docs/requirements.md` — context for resolving spec terms (read-only).
- `.scrum/test-results.json` — written by the preceding `smoke-test`
  run; this skill appends a new category to it.
- `.scrum/sprint.json.id` — current sprint id, used in output paths.

## Outputs

- `.scrum/design-verification-<sprint-id>.md` — verification matrix:
  one section per inventory item plus a summary table at the top.
- `.scrum/design-verification-<sprint-id>.app.log` — captured app
  stdout/stderr from any live-scenario phase.
- `.scrum/test-results.json` — a new TestCategory appended with
  `name: "design_completeness"`; `overall_status` recomputed in place.
- A gap report sent to the SM via `SendMessage`.

## Preconditions

- `state.json.phase == "integration_sprint"`.
- `smoke-test` has completed and its categories are recorded in
  `.scrum/test-results.json`.
- If no design specs are enabled (`catalog-config.json.enabled` empty
  or `docs/design/specs/` absent), record the category as `skipped`
  with reason `no enabled design specs`, report to SM, exit. Mirrors
  the smoke-test "None detected → skipped" convention.

## Steps

### 1. Build the functional inventory

Read every enabled spec ID from `catalog-config.json`, open the
corresponding `docs/design/specs/{category}/{id}-{slug}.md`, and
extract concrete, externally observable functional assertions per
catalog category:

- **Interface (S-020..S-023)** — endpoints, request/response
  contracts, error responses, event/message contracts.
- **UI (S-030..S-034)** — screens, navigation transitions,
  user-visible flows.
- **Logic (S-040..S-042)** — business rules, state-machine
  transitions, scheduled-job effects.
- **Data (S-010..S-012)** — persistence behaviors, integrity
  constraints, pipeline outputs.
- **System-wide (S-001..S-005)** — component wiring, startup paths,
  cross-component data flow.
- **Quality / Operations / Documentation specs** — only
  behavior-bearing assertions (e.g. error-handling behavior from
  S-052); purely descriptive content → mark `not_testable` with a
  reason.

Each item gets:

- `id`: `<spec-id>-F<NN>` (1-based per spec).
- `source`: spec file path + section anchor.
- `description`: verbatim-ish function description.
- `verification_method`: planned check (curl / CLI / Playwright MCP
  / store query / mapped test reuse).

**Granularity rule.** Integration level — verify cross-component
behavior on the running system. Not unit internals. Not subjective
UX.

### 2. Map to existing automated coverage

For each item, search the project's integration / E2E test suites
(file names, test descriptions, route handlers under test) for a
test that exercises the behavior. If a mapping exists AND that
suite passed in the smoke-test run recorded in
`.scrum/test-results.json`, the verdict is `pass` and the evidence
is the test file/case path. Do **not** re-run mapped suites.

### 3. Execute live scenarios for unmapped items

1. Start the app, reusing the detection order
   `README.md` Run/Quickstart section → `package.json` scripts
   (`start`/`dev`) → `Makefile` (`run`/`start`/`dev`) →
   `docker-compose.yml`. Same approach as `smoke-test` step 4 and
   `po-acceptance` step 1.
2. Launch in the background; redirect stdout/stderr to
   `.scrum/design-verification-<sprint-id>.app.log`.
3. Probe readiness with curl retry (10× at 2-second intervals) for
   HTTP services, or `--version` / `--help` for CLI / library
   targets.
4. For each unmapped item, run a verification command:
   - HTTP → `curl -s -o /dev/null -w '%{http_code}'`, or include
     a body slice when an assertion needs it.
   - CLI → the subcommand documented by the spec; capture exit
     code + stdout/stderr.
   - Browser flow → Playwright MCP navigate / click / form-fill.
   - Data assertion → query the persistence store the spec names
     (`sqlite3`, `psql`, `redis-cli`, etc.).
5. Capture the exact command line, exit code, and a ≤ 50-line
   output slice (prefer the assertion-bearing fragment). No
   credentials or tokens in the transcript.
6. Stop the app after the last unmapped item: `SIGTERM` → 5 s
   grace → `SIGKILL` (or `docker compose down`).

**Startup failure handling.** If readiness never returns OK, do
**not** try to fix the app. Mark every unmapped item `fail` with
rationale `APP_STARTUP_FAILED — see design-verification-<sprint-id>.app.log`,
finish the matrix and category record, then report to SM.

### 4. Assign verdicts

Exactly one of:

- `pass` — covered by a passing mapped test, or live-verified
  successfully.
- `fail` — behavior is present but does not match the spec.
- `missing` — the spec'd function has no implementation. This is a
  completeness violation and **counts as failed** in the category
  totals.
- `not_testable` — the assertion cannot be expressed as a runnable
  integration check (e.g., purely descriptive prose). Counts as
  skipped. **Reason is mandatory.** The full `not_testable` list
  MUST be surfaced to the SM so the PO sees it before UAT.

Never silently drop an inventory item.

### 5. Write the verification matrix

Write `.scrum/design-verification-<sprint-id>.md`:

- Summary table at the top: totals per verdict
  (`pass`/`fail`/`missing`/`not_testable`).
- One section per item:
  - `id`, source spec anchor, verdict.
  - Command line + exit code + output slice, or mapped test
    file/case path used as evidence.
  - Rationale for `fail` / `missing` / `not_testable` (required).

### 6. Record the TestCategory

Record the `design_completeness` category via the wrapper (it appends
to the `.scrum/test-results.json` the preceding `smoke-test` created,
creating it if absent, and recomputes `overall_status` in place —
direct edits are blocked by the scrum-state guard):

```bash
.scrum/scripts/record-test-result.sh \
  --name design_completeness --status <passed|failed|skipped> \
  --total <inventory-size> --passed <#pass> --failed <#fail + #missing> \
  --skipped <#not_testable> \
  --runner-command 'design-completeness-check' --executed-at <ISO8601> \
  [--error 'ITEM_ID::one-line reason']   # repeatable, max 10
```

Field derivation:

- `--status`: `failed` if any `fail` or `missing`; `skipped` if the
  whole skill skipped per Preconditions; otherwise `passed`
  (`not_testable` items count in `--skipped` but do not fail the
  category).
- `--failed`: `fail` + `missing`.
- `--skipped`: `not_testable`.
- `--error`: up to 10, one per `fail`/`missing` item — `ITEM_ID` is
  the item id, message a one-line reason. Prefix the message with
  `missing:` for `missing` items so the SM can spot completeness gaps
  at a glance.

The wrapper recomputes `overall_status` (ANY failed → `"failed"`; all
non-skipped passed + ANY skipped → `"passed_with_skips"`; all passed,
none skipped → `"passed"`).

### 7. Report to SM

Send the SM via `SendMessage`:

- Totals per verdict.
- Explicit gap list — every `fail`, `missing`, and `not_testable`
  item id with a one-line reason.
- Matrix path: `.scrum/design-verification-<sprint-id>.md`.

Ref: FR-013

## Exit Criteria

- `.scrum/design-verification-<sprint-id>.md` exists.
- `design_completeness` TestCategory recorded in
  `.scrum/test-results.json`; `overall_status` recomputed.
- Gap report sent to SM.
- App stopped.

## Strict Rules

- The verifier **never** fixes defects discovered during this skill.
  Defects route through SM → PBI per `FR-010`.
- The verifier **never** edits source code or design specs while
  this skill runs.
- Functions not in an enabled spec are out of scope — no
  spec-invention. Catalog governance (`docs/design/catalog.md`)
  applies.
- A `missing` item **never** gets reclassified as `not_testable` to
  dodge the failed-count. `not_testable` means "cannot express the
  check as a runnable integration scenario", not "no implementation
  yet".
- A spec assertion is **never** lowered to make verification pass.
  Ambiguous assertions become `not_testable` with a rationale.
