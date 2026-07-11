# Test automation — automate first, record verdicts

This reference is the methodology for **Step 6** of the
`integration-tests` skill. It executes the test-case matrix,
automating as much as possible, and records the verdicts through the
`record-test-result.sh` wrapper. The verdict discipline is inherited
verbatim from the retired `design-completeness-check` skill.

## Automation-first order

For each case in the matrix, pick the highest applicable execution
tier. A lower tier requires a stated reason recorded in the case's
`automation` field.

### 1. `automated` (default) — committed, re-runnable code

- **API cases** → implement as tests in the **project's own test
  library** and commit under `tests/integration/`. Match the
  project's language and idiom (e.g. a Python project uses its
  established HTTP-test approach, a Node project its, a Go project
  `go test`). Confirm the current, maintained test/HTTP-client library
  for the stack with a Web search at implementation time rather than
  from memory (same discipline as `../../../agents/pbi-designer.md` §
  Mandatory library selection).
- **UI cases** → implement as **Playwright test code** (`npx
  playwright test`, not the MCP) and commit under `tests/e2e/`. This
  is a persistent asset the target project keeps and re-runs.
- These tests bring up the app and any `tests/stubs/` fixtures they
  need (stub endpoints selected via environment variable — see
  [stub-construction.md](stub-construction.md)) and tear them down
  after.
- If the app never reaches readiness (startup does not converge), do
  **not** fix the app — record the unexecuted cases as `fail` with the
  reason `APP_STARTUP_FAILED` and report it to the SM as a defect
  (carried over from the retired `design-completeness-check` discipline:
  a system that will not start is a completeness failure, not a
  `not_testable` skip).

### 2. `claude-manual` — Claude drives, only when automation is not viable

Use only for cases that genuinely cannot be expressed as committed
code (e.g. a one-off visual/behavioral check with no stable selector).
Claude drives the running app via a browser MCP and records evidence:

- **Playwright MCP** is the primary path: navigate / click / form-fill
  / screenshot.
- **Chrome DevTools MCP** is the auxiliary path when the case needs
  console-error, network-failure, or performance-trace inspection.
- **Evidence is mandatory**: an operation log plus screenshot(s)
  saved under the sprint's artifacts, referenced from the case.
- If neither MCP is configured, do **not** silently skip: fall back to
  tier 3 and warn (state which MCP to enable, mirroring the
  `smoke-test` graceful-skip convention).

### 3. `human-manual` — checklist for a person

For cases that cannot be automated **and** cannot be Claude-driven,
emit a human-manual checklist item (step + expected result) and carry
it into the UAT preamble (via the Step 7 SM report) so the PO / user
probes it by hand. These items are recorded under the `manual_probe`
category (see below), never silently dropped.

## Report the automation rate

The SM report MUST state the **automation rate** =
`automated cases / total cases`, plus counts for `claude-manual` and
`human-manual`. A falling automation rate is a signal, not a target to
game — do not downgrade a case to a lower tier to avoid writing a test.

## Verdicts

Every executed case gets exactly one verdict:

- `pass` — behavior matches the spec.
- `fail` — behavior is present but does not match the spec.
- `missing` — the spec'd function has no implementation. A
  completeness violation; **counts as failed**.
- `not_testable` — the assertion cannot be expressed as a runnable
  integration check. Counts as skipped. **Reason mandatory**; the full
  `not_testable` list is surfaced to the SM before UAT.

Non-negotiable (carried over from `design-completeness-check`):
`missing` is **never** relabeled `not_testable`; a spec assertion is
**never** lowered to make a case pass; no inventory item is silently
dropped.

## Record via the wrapper

All writes to `.scrum/test-results.json` go through
`.scrum/scripts/record-test-result.sh` — direct edits are blocked by
the scrum-state guard. The wrapper creates the file on first call,
upserts each category by `--name` (a re-run after a fix replaces the
prior result), and recomputes `overall_status` on every call. Record
one call per category:

| category | covers |
|----------|--------|
| `integration_api` | automated API cases (`tests/integration/`) |
| `integration_ui` | automated UI cases (`tests/e2e/`) |
| `design_coverage` | the spec ⇄ case completeness judgment (replaces the retired `design_completeness` category) |
| `manual_probe` | `claude-manual` + `human-manual` cases |

```bash
.scrum/scripts/record-test-result.sh \
  --name integration_api --status <passed|failed|skipped> \
  --total <#cases> --passed <#pass> --failed <#fail + #missing> \
  --skipped <#not_testable> \
  --runner-command '<runner>' --executed-at <ISO8601> \
  [--error 'TC-NNN::one-line reason']   # repeatable, max 10
```

Field derivation (per category):

- `--status`: `failed` if any `fail` or `missing`; `skipped` if the
  category had no runnable cases (e.g. no enabled specs, or no UI);
  otherwise `passed`. `not_testable` counts in `--skipped` and does
  **not** fail the category.
- `--failed`: `fail` + `missing`.
- `--skipped`: `not_testable`.
- `--error`: up to 10, one per `fail`/`missing` case. Prefix the
  message with `missing:` for `missing` items so the SM can spot
  completeness gaps at a glance.

The wrapper recomputes `overall_status`: ANY category failed →
`"failed"`; else ANY skipped → `"passed_with_skips"`; else
`"passed"`. That combined status is what the Step 7 quality gate reads.

## Do not fix

Defects found here **never** get fixed inside this skill. The tester
does not edit product source or specs; every defect routes SM → PBI
per `FR-010`. **No fix without an assigned PBI.**
