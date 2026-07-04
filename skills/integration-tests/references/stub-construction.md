# Stub construction — external interfaces

This reference is the methodology for **Step 5** of the
`integration-tests` skill. It builds stubs for the external interfaces
that cannot be exercised locally, so the S-022 scenarios from the
test-case matrix can run deterministically.

## What to stub (and what not to)

Stub **only** interfaces that are not locally reproducible: third-party
HTTP APIs, payment / auth / mail / SaaS providers, partner webhooks,
and any dependency whose real invocation is non-deterministic, costs
money, or is unavailable in the test environment.

Do **not** stub components the project owns and can run locally
(its own database, cache, queue, sibling services) — run the real
thing. Enumerate the external interfaces by reading the enabled
**S-022 External Integration** specs (one per external service) and
cross-checking the source for outbound calls.

## Contract is the only source of truth

Each stub is a **mapping of its S-022 contract** — request shape,
response shapes, status codes, error conditions, timeout behavior.

- A stub **never invents behavior** the spec does not state. If the
  contract is silent on a case the test needs, that is a spec gap:
  raise it (the S-022 spec is ambiguous → `not_testable` with a
  rationale, surfaced to the SM), do not guess a response.
- The stub reproduces exactly the scenarios the matrix requires:
  normal response, each documented error response, timeout, and
  malformed/unexpected payload.

## Placement and switching

- Stubs live in the target project's `tests/stubs/` and are
  **committed** (a persistent, re-runnable asset). They are started
  and stopped by the test runner and are never used outside tests.
- **Connection switching is by environment variable** (e.g. a base-URL
  or endpoint override the client already reads). The product code
  MUST NOT contain a stub branch, an `if TEST` fork, or any
  test-awareness. If the client has no injectable endpoint, that is a
  testability defect — record it as a `fail`/PBI, do not patch a
  branch into production code.

## Method priority

Pick the highest applicable method:

1. **Contract-driven mock from an API definition** — if the service
   has an OpenAPI / schema definition, generate a mock from it so the
   stub stays faithful to the contract by construction.
2. **Language-native mock server** — a maintained mock-server /
   request-interception library for the project's stack.
3. **Minimal hand-written fixture server** — a small local server that
   returns the fixture responses the matrix needs. Last resort; keep
   it to the documented contract only.

Concrete tool/library names change over time. **At implementation
time, run a Web search to confirm the current, actively maintained
tool** for the chosen method and the project's language before
adopting one — do not select a library from training-data memory.
This is the same library-selection discipline the `pbi-designer`
applies (see `agents/pbi-designer.md` § Mandatory library selection &
verified-spec research): prefer a proven track record and use-case
fit, and verify API facts from the tool's own docs.

## Output

- `tests/stubs/**` — the committed stubs, one per external service,
  each traceable to its S-022 spec anchor.
- The S-022 test cases in the matrix reference the stub they run
  against; the test runner brings the stub up before those cases and
  down after (see [test-automation.md](test-automation.md)).
