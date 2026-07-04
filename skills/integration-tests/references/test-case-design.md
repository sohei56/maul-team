# Test-case design — spec → cases

This reference is the methodology for **Step 4** of the
`integration-tests` skill. It turns the enabled design specs into a
concrete, executable test-case matrix that covers boundary values,
flow branches, and pattern branches. It absorbs and supersedes the
functional-inventory method of the former `design-completeness-check`
skill: the old "one function = one happy-path check" inventory is the
lower bound of this matrix (every function is still enumerated), now
extended across boundaries and branches.

## Inputs

- `docs/design/catalog-config.json` — the `enabled` spec IDs (the SSOT
  for what is in scope). If it is empty or `docs/design/specs/` is
  absent, record the `design_coverage` category as `skipped` with
  reason `no enabled design specs`, report to the SM, and skip the
  rest of the derivation.
- `docs/design/specs/{category}/{id}-{slug}.md` — each enabled spec.
- `docs/requirements.md` — read-only context for resolving terms.

## Output: the test-case matrix

Write `.scrum/integration-tests/<sprint-id>/test-cases.md`
(`<sprint-id>` = `.scrum/sprint.json.id`). It has two parts.

### 1. Case table

One row per test case. Each case carries these fields:

- `id` — `TC-<NNN>` (zero-padded, 1-based across the whole matrix).
- `source` — the spec **anchor** the case derives from: spec file path
  plus section anchor (e.g.
  `docs/design/specs/interface/S-020-orders.md#post-orders`). One
  anchor per case; a case verifies exactly one spec assertion.
- `title` — one line naming the behavior under test.
- `input` — the concrete request / action / precondition (method,
  path, params, form fields, starting state — whatever the case needs
  to be run without further interpretation).
- `expected` — the observable expected result taken from the spec
  (status code, response shape/slice, resulting state, screen, error
  contract). Never weaken the spec's assertion to make it pass.
- `automation` — exactly one of `automated` | `claude-manual` |
  `human-manual`. This drives Step 6. Default to `automated`; only
  downgrade with a stated reason (see
  [test-automation.md](test-automation.md)).

### 2. Traceability table

A `spec anchor ⇄ case id` table proving coverage. For every enabled
spec, list **each branch and each boundary** the derivation rules
below identify, and the case id(s) that cover it. The uncovered list
MUST be **empty**, or each uncovered item MUST carry an explicit
`waive: <reason>` (e.g. purely descriptive prose that cannot be
expressed as a runnable check — this is the `not_testable` verdict).
Never silently drop a branch or boundary.

## Per-category derivation rules

Read each enabled spec and apply the rule for its catalog category.
Verify at **integration granularity** — cross-component behavior on the
running system, not unit internals and not subjective UX.

### Interface — S-020 (API), S-021 (Event/Message), S-023 (Realtime)

For each endpoint / channel × parameter, derive:

- **Equivalence partitioning**: one representative valid case per
  meaningful input class.
- **Boundary values**: min, max, min−1, max+1, empty, null,
  wrong-type, malformed-format for each constrained parameter.
- **Error-response contract**: each documented 4xx/5xx condition
  (validation failure, not-found, conflict, server error) with its
  expected status and error body shape.
- **AuthN / AuthZ boundary**: unauthenticated, authenticated but
  unauthorized, and authorized — for every access-controlled route.

### Business Rule / Domain Logic — S-040

Build a **decision table**: enumerate the condition variables the rule
names and cover their combinations (pattern-branch coverage). For each
numeric or ordered threshold, use boundary values at the threshold and
±1. Each covered combination and each boundary is one case.

### Workflow / State Machine — S-042

Achieve **state-transition coverage**: every defined transition
exercised at least once (flow-branch coverage), plus a rejection case
for each **invalid** transition the spec forbids. Cover terminal states
and guard conditions.

### UI — S-030..S-034

- **S-033 (Navigation/Routing)**: every screen-to-screen transition
  exercised (screen-flow coverage).
- **S-030/S-031 (Screen/Component)**: form-validation **boundary
  values** (required, length limits, format rules) and their error
  displays.
- **S-034 (UX Flow / User Journey)**: each end-to-end user journey as
  a single E2E flow case.

### External Integration — S-022

Derive **stub-backed scenarios** for each external service: normal
response, error response (each documented failure), timeout, and
malformed/unexpected payload. These cases run against the stubs built
in Step 5 (see [stub-construction.md](stub-construction.md)).

### Other catalog categories

For Data (S-010..S-012), System-wide (S-001..S-005), and Quality /
Operations specs, derive cases only from **behavior-bearing,
externally observable** assertions (persistence effects, startup
wiring, error-handling behavior). Purely descriptive prose becomes a
traceability row with `waive: not_testable — descriptive only`.

## Verdicts (recorded in Step 6, inherited discipline)

When a case is executed, its verdict is exactly one of:

- `pass` — behavior matches the spec.
- `fail` — behavior is present but does not match the spec.
- `missing` — the spec'd function has no implementation. A
  completeness violation; **counts as failed**.
- `not_testable` — the assertion cannot be expressed as a runnable
  integration check. Counts as skipped. **A reason is mandatory**, and
  the full `not_testable` list MUST be surfaced to the SM so the PO
  sees it before UAT.

`missing` is **never** relabeled `not_testable` to dodge the failed
count, and a spec assertion is **never** lowered to make a case pass —
an ambiguous assertion becomes `not_testable` with a rationale. These
rules are non-negotiable and carry over verbatim from the retired
`design-completeness-check` skill.
