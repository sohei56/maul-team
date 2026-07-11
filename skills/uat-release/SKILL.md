---
name: uat-release
description: >
  UAT & Release — user-acceptance testing of the integrated product
  followed by the release decision. Entered from Integration Tests
  once automated tests pass; drives UAT, defect collection, defect→PBI
  routing, and the go/no-go release gate.
disable-model-invocation: false
---

## Inputs

- state.json → phase: "integration_sprint" (entered after
  integration-tests reported passing automated tests)
- `.scrum/test-results.json` — precondition:
  `overall_status ∈ {passed, passed_with_skips}` (produced by the
  `integration-tests` skill).
- integration-tests hand-off artifacts: the `human-manual`
  verification checklist and the `not_testable` item list surfaced by
  the test-case matrix. Both are folded into the UAT preamble so the
  PO/user probes them manually.
- `docs/requirements.md` — the FR/NFR set from which user stories are
  exhaustively derived.
- `docs/product/vision.md` release-criteria section (cross-check;
  the brief is the fallback when vision.md is absent).

## Outputs

- `.scrum/po/uat-stories-<sprint-id>.md` — UAT user-story inventory
  derived from `docs/requirements.md` with an FR⇄US traceability
  appendix; verdict (`pass | fail | waive` + feedback) recorded per
  story during the walkthrough.
- `.scrum/po/uat-<sprint-id>.md` — per-story UAT transcript
  (`## US-NNN` sections). For UI stories this carries browser-driven
  evidence (operation log + expected/observed + screenshot
  references) per `references/po-browser-uat.md`.
- `CLAUDE.md` — project root, fully regenerated at release (directory
  structure + system architecture + conventions, ~200 lines target).
  **Overwrites prior content including manual edits.**
- `.scrum/po/claude-md-backup-<UTC-ISO8601>.md` — pre-regeneration
  backup of `CLAUDE.md` (agent mode only).
- state.json → phase: "uat_release" → "complete" when release-ready,
  or → "backlog_created" when UAT defects route back to development.

## Preconditions

- `integration-tests` completed with
  `.scrum/test-results.json.overall_status ∈ {passed,
  passed_with_skips}`. If this does not hold, do **not** run UAT:
  move phase back to `integration_sprint`
  (`.scrum/scripts/update-state-phase.sh integration_sprint`) and
  hand back to the `integration-tests` skill.
- requirements.md exists.

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, every PO-approval prompt
in the Steps below re-targets to the `product-owner` teammate per
`../../rules/scrum-context.md` § PO seat resolution; the ceremony shape is
unchanged, and Steps not overridden in this table run verbatim.

| Step                          | Override (po_mode=agent)                                                                                                                                                                                                                                                                                                                                                                  |
|-------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2. UAT (mandatory)            | Replace the human walkthrough. SM messages the PO teammate; the PO runs the `po-acceptance` skill with `mode=uat` on its own (the skill lives in the PO's allowlist, not the SM's). The PO builds the user-story inventory `.scrum/po/uat-stories-<sprint-id>.md` itself by exhaustively deriving stories from `docs/requirements.md` (FR⇄US traceability appendix; uncovered-FR list MUST be empty or carry waiver rationale) cross-checked against `docs/product/vision.md` release-criteria section, launches the app, and verifies each story one at a time. UI stories are driven through the browser (Playwright MCP navigate / click / form-fill / screenshot, Chrome DevTools MCP for console / network / display checks) per `references/po-browser-uat.md`; non-UI stories use runnable commands. Returns one `kind=uat_item` decision per story. `unverifiable` items become `fail` unless `waive` with rationale. |
| 3. Defect collection          | The `any other issues?` loop collapses to a single structured pass: the PO concludes the `PO_ACCEPTANCE_REPORT` (failed stories listed as US-NNN with feedback) with its own self-review of adjacent features / shared components and terminates with `FEEDBACK_COMPLETE`. No further round-trips.                                                                                        |
| 4. Return to Development      | **Re-entry cap:** the integration→development→integration loop may execute at most `.scrum/config.json.po.max_integration_cycles` (default `3`) times. On exceeding the cap, do **not** continue; emit `[product] PO_DECISION kind=release_decision decision=no_go rationale=integration_cycle_cap_hit cap=<n>`, append a release-blocking entry to `.scrum/po/attention.md` enumerating remaining defects, materialise each remaining defect as a `known-issues` draft PBI in `.scrum/backlog.json`, then halt the skill in a safe parked state for human morning review. |
| 5. Release decision          | "User confirms release-ready" → `[product] PO_DECISION_REQUEST kind=release_decision options=[go,no_go] recommendation=<...>`. `decision=go` is mechanically gated by `append-po-decision.sh` (requires `.scrum/test-results.json.overall_status ∈ {passed, passed_with_skips}`); a rubber-stamp `go` without passing results is rejected by the wrapper.                                  |
| 5a. CLAUDE.md regeneration   | The "warn user before overwriting" prompt is non-interactive in agent mode: if `CLAUDE.md` exists, the Developer first copies it to `.scrum/po/claude-md-backup-<UTC-ISO8601>.md` (writable PO-scoped path), then regenerates. The backup path is recorded in the `release_decision=go` decision's `--evidence`. No human wait.                                                            |

## Steps

1. **Enter UAT & Release** — transition phase and confirm the gate:
   ```bash
   .scrum/scripts/update-state-phase.sh uat_release
   ```
   - Precondition check:
     `.scrum/test-results.json.overall_status ∈ {passed,
     passed_with_skips}`. If not met, move phase back with
     `.scrum/scripts/update-state-phase.sh integration_sprint` and
     hand back to `integration-tests` — do **not** start UAT on
     failing automated tests.
   - `passed_with_skips` → inform the user (PO) which categories
     skipped and why; note the skipped areas in the UAT walkthrough
     preamble.
   - Fold the integration-tests `human-manual` checklist and
     `not_testable` item list into the UAT preamble so the PO/user
     probes them manually during the walkthrough.
2. **UAT (mandatory)** — user-story driven, verified one story at a
   time:
   a. Derive the user-story inventory **exhaustively** from
      `docs/requirements.md` and write
      `.scrum/po/uat-stories-<sprint-id>.md`. Each story uses id
      `US-NNN` (zero-padded, 1-based), the
      `As a <user>, I want <action>, so that <benefit>` form,
      source FR refs (e.g. `FR-003`), a concrete verification
      scenario (steps a user would perform), and a verdict field
      (`pass | fail | waive` + feedback) filled during the
      walkthrough. Append an FR⇄US traceability appendix: every
      release-relevant FR maps to ≥1 story, every story maps to
      ≥1 FR. User-observable NFRs (e.g. response time a user can
      feel) get stories; purely internal NFRs are listed as
      excluded with a reason. The uncovered-FR list MUST be empty
      before the walkthrough starts (or each uncovered FR carries
      an explicit waiver rationale).
   b. Present the full story list to the user (PO) for
      **completeness confirmation** — additions/removals are
      applied to the inventory before any walkthrough starts.
      Also surface the `not_testable` items from the integration-tests
      test-case matrix so the PO can probe them manually.
   c. Verify app running (re-launch if stopped) → tell user access
      point.
   d. Walk stories **one at a time**: present the story + its
      verification scenario steps → user performs/observes → ask
      "works as expected?" → wait → record verdict + feedback in
      the inventory → next story. **Never** present multiple
      stories in one prompt. Stories with a UI are exercised through
      the browser and leave screenshot evidence
      (see `references/po-browser-uat.md`).
   e. Record results → failed stories go to step 3.
   - **po_mode=agent**: skip 2a–e. SM messages the PO teammate; the
     PO runs `po-acceptance` (mode=uat) on its own (the skill is on
     the PO's allowlist, not the SM's). The PO builds the same
     user-story inventory `.scrum/po/uat-stories-<sprint-id>.md`
     itself (derived from `docs/requirements.md`, cross-checked
     against the `docs/product/vision.md` release-criteria section)
     and verifies each story, driving UI stories through Playwright
     MCP / Chrome DevTools MCP with screenshot evidence per
     `references/po-browser-uat.md` (falling back to runnable
     commands when a browser MCP is absent), returning one
     `kind=uat_item` decision per story. `unverifiable` becomes
     `fail` unless `waive` with rationale (per `po-acceptance`).
3. **Defect collection (no fixing yet)**:
   a. Present failed stories (US-NNN + feedback) → "any other
      issues?" → repeat until user says "that's all".
   b. SM self-review: related code, adjacent features, shared
      components → propose additional fixes → user confirmation.
   c. Consolidate full defect list → user confirms complete.
   - **po_mode=agent**: collapse 3a–c into the single
     `PO_ACCEPTANCE_REPORT` returned by `po-acceptance` (mode=uat).
     The PO appends its own self-review of adjacent features and
     terminates with `FEEDBACK_COMPLETE`. No iterative loop.
   d. **Defect→PBI**: Each confirmed defect → backlog.json PBI
      (status: draft → immediately refined, acceptance_criteria:
      expected vs actual, priority by severity). **No fix without
      assigned PBI — non-negotiable.**
4. **Return to Development Sprint**: state.json → phase:
   "backlog_created" → normal Sprint cycle (Refinement → Planning →
   Design → Implementation → Review → Sprint Review → Retrospective)
   → after fix Sprint → re-evaluate Product Goal → re-enter
   Integration Tests:
   ```bash
   .scrum/scripts/update-state-phase.sh backlog_created
   ```
   - **po_mode=agent**: this re-entry counts against
     `.scrum/config.json.po.max_integration_cycles` (default `3`).
     On cap-hit, do not return to development; instead emit
     `kind=release_decision decision=no_go
     rationale=integration_cycle_cap_hit cap=<n>`, append a
     `release-blocking: yes` entry to `.scrum/po/attention.md`
     listing every remaining defect, materialise each remaining
     defect as a `known-issues` draft PBI in `.scrum/backlog.json`,
     then halt the skill in a parked safe state for human morning
     review.
5. **Release decision**: User confirms release-ready →
   a. **CLAUDE.md regeneration**: Delegate Developer → fully
      regenerate `CLAUDE.md` at project root:
      - **Directory structure** (current state, scanned from
        filesystem)
      - **System architecture overview** (components, data flow, key
        integrations)
      - **Tech stack + key conventions** (commands, code style,
        status flows)
      - Target ~200 lines (目安). Exceeded → warn user, do not block.
      - **Full regeneration**: prior content overwritten. Warn user
        before write if existing CLAUDE.md has content not derivable
        from requirements.md/code (manual edits at risk).
   b. state.json phase: "complete":
      ```bash
      .scrum/scripts/update-state-phase.sh complete
      ```
   Not ready → identify remaining work → Development Sprint (step 4).
   - **po_mode=agent**: `[product] PO_DECISION_REQUEST
     kind=release_decision options=[go,no_go] recommendation=<...>`.
     `decision=go` is gated by `append-po-decision.sh` (rejects
     unless `.scrum/test-results.json.overall_status ∈ {passed,
     passed_with_skips}`) — rubber-stamp `go` is mechanically
     impossible. On `go`, before regenerating CLAUDE.md the Developer
     copies the existing file to
     `.scrum/po/claude-md-backup-<UTC-ISO8601>.md` (PO-writable path)
     and records that backup path as `--evidence` on the
     `release_decision` decision; the regeneration then proceeds
     without a human wait. `no_go` returns to step 4 (subject to the
     re-entry cap above).

Ref: FR-013

## Exit Criteria

- UAT user-story inventory `.scrum/po/uat-stories-<sprint-id>.md`
  exists with FR⇄US traceability appendix (uncovered-FR list empty
  or explicitly waived) and every story has a recorded verdict
  (`pass | fail | waive` + feedback).
- UAT transcript `.scrum/po/uat-<sprint-id>.md` exists with a
  `## US-NNN` section per story; UI stories carry browser evidence
  (screenshot references) per `references/po-browser-uat.md`.
- Release confirmed → `CLAUDE.md` regenerated + phase: "complete",
  OR new defect PBIs created + phase: "backlog_created".
