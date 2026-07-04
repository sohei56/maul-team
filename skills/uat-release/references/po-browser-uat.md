# PO browser-driven UAT protocol

This reference defines how the `product-owner` teammate exercises
**UI user stories** during `po_mode=agent` UAT (step 2 of
`uat-release`, run via `po-acceptance` with `mode=uat`). It is the
canonical home for the browser-driving protocol; `po-acceptance`
points here rather than restating it.

The goal is the same as any other verdict: turn each user story into
an executed, evidenced check whose result is `pass | fail | waive`.
For UI stories the executed check is a **browser session with
screenshot evidence**, not a hand-wave that "the UI looks fine".

## When browser driving applies

Use browser driving as the **first choice** for any story whose
verification scenario involves a rendered page, a form, navigation
between screens, or a visible UI state. Non-UI stories (pure CLI,
HTTP-API, or data-store assertions) continue to use the runnable
commands described in `po-acceptance` step 3.

## Tooling

Two MCP servers may be present. Detect them from `.mcp.json`
(`mcpServers.*`) before use — do **not** assume either is installed.

- **Playwright MCP — primary path.** Drives the browser end to end:
  navigate to the access point, click through the scenario, fill and
  submit forms, assert on rendered content, and capture screenshots.
  This is the default for every UI story.
- **Chrome DevTools MCP — auxiliary path.** Add it for stories where
  the verdict depends on things Playwright's DOM view does not
  surface: JavaScript console errors, failed network requests
  (4xx/5xx, blocked resources), or user-perceptible display /
  performance problems (layout, load timing). Use it **alongside**
  Playwright for those stories, not instead of it.

Both servers are optional in a target project's `.mcp.json`. Whether
a `chrome-devtools` server is configured is a deployment concern, not
this skill's — reference it only conditionally ("if `.mcp.json`
defines a `chrome-devtools` server, also …"). Do not name packages or
launch arguments here.

## Verification loop (per UI story)

1. **Launch / confirm the app** is reachable (per `po-acceptance`
   step 1). Note the access point (base URL).
2. **Drive the scenario with Playwright MCP.** Execute the story's
   verification steps as browser actions: `navigate` to the entry
   screen, `click` / `form-fill` through the flow, and read back the
   rendered result. Capture a **screenshot at each asserting step**
   (at minimum: the initial state and the final observed outcome).
3. **Inspect with Chrome DevTools MCP when relevant.** For stories
   that must be free of console errors, network failures, or display
   regressions, and when a `chrome-devtools` server is configured,
   collect the console log, the failed-request list, and (if the
   story names it) a load/performance reading.
4. **Compare** the observed rendered state against the story's
   expectation and assign the verdict:
   - `pass` — the flow completed and the UI matched expectations
     (and, when in scope, no console/network/display faults).
   - `fail` — the flow did not complete, the UI did not match, or a
     console/network/display fault contradicts the story.
   - `unverifiable` — the story cannot be reduced to an observable
     browser check. **Not a terminal verdict**: record it as `fail`
     unless the PO `waive`s it with an explicit rationale naming the
     gap and the evidence that would lift the waiver. Never mark an
     `unverifiable` story `pass`.

## Evidence

Record every UI story under its `## US-NNN` anchor in
`.scrum/po/uat-<sprint-id>.md`. Each section carries:

- **Operation log** — the ordered browser actions taken
  (navigate/click/fill targets), so the run is reproducible.
- **Expected vs. observed** — the story expectation and the actual
  rendered result (and, when inspected, the console/network/display
  findings).
- **Screenshot references** — paths to the captured screenshots
  (store under `.scrum/po/uat-<sprint-id>.assets/` or the path your
  MCP writes to) linked from the section, keyed to the asserting
  steps.
- **verdict** + **rationale** (rationale required for `fail` and
  `waive`), matching the transcript field contract in `po-acceptance`
  step 4. The screenshot references populate `evidence_extras`.

## Fallback when no browser MCP is present

If neither Playwright MCP nor Chrome DevTools MCP is configured in
`.mcp.json`, fall back to the runnable-command verification already
defined in `po-acceptance` step 3 (HTTP probe of the rendered
endpoint, or the CLI/data-store assertion the story allows), and note
in the transcript that browser evidence was unavailable. A story that
can only be judged visually and has no browser MCP is `unverifiable`
→ `fail` unless `waive`d with rationale — the bar is never lowered to
make UAT pass.
