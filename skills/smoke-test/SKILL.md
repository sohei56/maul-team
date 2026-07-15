---
name: smoke-test
description: >
  Smoke Test — automated test execution for Integration Sprint. Detects
  test frameworks, runs all tests, performs HTTP smoke testing, optionally
  runs browser E2E via Playwright MCP, and records results to
  .scrum/test-results.json.
disable-model-invocation: false
---

## Inputs

- state.json → phase: "integration_sprint"
- requirements.md (endpoint/workflow discovery)
- Project source code

## Outputs

- `.scrum/test-results.json`

## Preconditions

- Developer teammate assigned to Integration Sprint testing
- ≥1 Development Sprint completed (tests exist)

## Steps

### 1. Record via the wrapper (no manual init)

All writes to `.scrum/test-results.json` go through
`.scrum/scripts/record-test-result.sh` — direct edits are blocked by the
scrum-state guard. The wrapper **creates the file on the first call**,
upserts each category by `--name` (re-running a suite after a fix
replaces that category's prior result instead of duplicating it), and
**recomputes `overall_status` automatically** on every call. No manual
initialization step is needed.

### 2. Detect test frameworks

Check project root, collect ALL matches:
- package.json "test"→`npm test` (unit)
- package.json "test:e2e"→`npm run test:e2e` (e2e)
- package.json "test:integration"→`npm run test:integration` (integration)
- pytest.ini / pyproject.toml [tool.pytest] / tests/*.py→`python -m pytest` (unit)
- Cargo.toml→`cargo test` (unit)
- go.mod→`go test ./...` (unit)
- Makefile test target→`make test` (unit)
- tests/*.bats→`bats tests/` (unit)

None detected→status: "skipped", runner_command: "none detected"

### 3. Run detected tests

Each runner: execute→capture exit code + output→parse pass/fail counts→record the TestCategory via the wrapper:

```bash
.scrum/scripts/record-test-result.sh \
  --name unit --status passed \
  --total 15 --passed 15 --failed 0 --skipped 0 \
  --runner-command 'npm test' --executed-at <ISO8601> \
  [--error 'TEST_NAME::one-line reason']   # repeatable, max 10
```

The wrapper updates `updated_at` and recomputes `overall_status` on every call.

**Token efficiency**: Pipe test output through failure filter to minimize context consumption:
```bash
# Run tests, capture only summary + failures (not full passing test output)
<runner_command> 2>&1 | tail -n 50  # Last 50 lines typically contain summary + failures
```
For large test suites (>100 tests), use `grep -A 5 'FAIL\|Error\|✗\|FAILED'` to extract failure details only. Record full pass/fail counts from exit code + summary line, not from reading every test result line.

### 4. HTTP smoke testing

1. Find start command (package.json/Makefile/docker-compose etc)
2. Start app in background
3. Wait ready (curl retry 10x, 2s intervals)
4. Discover endpoints: route files, requirements.md, source code, OpenAPI specs
5. Curl each: GET→expect 2xx/3xx→4xx/5xx = failure
6. Stop app
7. Record TestCategory name: "smoke"

No start command→smoke status: "skipped"

**Token efficiency**: Use `-s -o /dev/null -w '%{http_code}'` with curl to capture status codes only, not response bodies. Log only failing endpoints (non-2xx/3xx).

### 5. Browser E2E (if Playwright MCP available)

Check `.mcp.json` for Playwright MCP.

**Available**: Ensure app running→Playwright MCP: navigate main URL→click all links/nav→verify no blank/error pages→fill+submit forms→verify requirements.md workflows→record TestCategory name: "browser"

**Not available**: status: "skipped". Warn user: Browser E2E skipped, Playwright MCP not configured. Enable by adding to `.mcp.json`: `{"mcpServers":{"playwright":{"command":"npx","args":["@anthropic-ai/mcp-playwright"]}}}`

### 6. overall_status (computed by the wrapper)

`record-test-result.sh` recomputes `overall_status` on every call from
all recorded categories — no manual write:

- ANY failed→"failed"
- ALL non-skipped passed + ANY skipped→"passed_with_skips"
- ALL passed, NONE skipped→"passed"

### 7. Report to SM

Overall status, per-category summary (e.g., unit: 15/15 passed), first 3 error details for failed categories, skipped category reasons + how to enable

Ref: FR-013

## Exit Criteria

- test-results.json exists with overall_status set
- All detectable categories executed or skipped
- Results reported to SM
