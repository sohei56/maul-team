---
name: integration-sprint
description: >
  Integration Sprint — product-wide quality assurance with integration,
  E2E, regression testing, and user acceptance testing. Triggered when
  the Product Goal is achieved.
disable-model-invocation: false
---

## Inputs

- state.json → phase: "retrospective"
- User confirmation Product Goal achieved

## Outputs

- `.scrum/test-results.json`
- `.scrum/design-verification-<sprint-id>.md` — design-completeness
  verification matrix produced by the `design-completeness-check` skill
- `.scrum/po/uat-stories-<sprint-id>.md` — UAT user-story inventory
  derived from `docs/requirements.md` with FR⇄US traceability
  appendix; verdict (`pass | fail | waive` + feedback) recorded per
  story during the walkthrough
- `CLAUDE.md` — project root, fully regenerated at release (directory structure + system architecture + conventions, ~200 lines target). **Overwrites prior content including manual edits**
- state.json → phase: "integration_sprint"→"complete" when release-ready

## Preconditions

- ≥1 Development Sprint completed
- User confirmed Product Goal sufficiently achieved
- requirements.md exists

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, the human user is not
the PO seat — the `product-owner` teammate is. The ceremony shape is
unchanged; only the destination of PO-approval prompts is re-targeted.
Apply the following overrides to the Steps below; everything not in
this table runs verbatim.

| Step                          | Override (po_mode=agent)                                                                                                                                                                                                                                                                                                                                                                  |
|-------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Inputs / start gate           | "User confirmation Product Goal achieved" is resolved by `[product] PO_DECISION_REQUEST kind=scope_change options=[approve,reject] recommendation=approve`. The PO compares `docs/product/vision.md` release-criteria section against `.scrum/backlog.json` (items with `status == done`) and rules `approve` (enter Integration Sprint) or `reject` with rationale (remain in development). |
| 5. Quality gate (`failed`)    | Replace "ask user for additional issues" with one structured PO pass: `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[high,medium,low,reject] recommendation=<...>` carrying the smoke-test failure list. PO returns priorities for each failure in a single reply. No human-input wait, no "any other issues" loop.                                                          |
| 6. UAT (mandatory)            | Replace 6a–e. SM invokes the `po-acceptance` skill with `mode=uat`. The PO builds the user-story inventory `.scrum/po/uat-stories-<sprint-id>.md` itself by exhaustively deriving stories from `docs/requirements.md` (FR⇄US traceability appendix; uncovered-FR list MUST be empty or carry waiver rationale) cross-checked against `docs/product/vision.md` release-criteria section, launches the app, verifies each story one at a time by runnable command, and returns one `kind=uat_item` decision per story. `unverifiable` items become `fail` unless `waive` with rationale. |
| 7. Defect collection          | The `any other issues?` loop collapses to a single structured pass: the PO concludes the `PO_ACCEPTANCE_REPORT` (failed stories listed as US-NNN with feedback) with its own self-review of adjacent features / shared components and terminates with `FEEDBACK_COMPLETE`. No further round-trips.                                                                                        |
| 9. Return to Development      | **Re-entry cap:** the integration→development→integration loop may execute at most `.scrum/config.json.po.max_integration_cycles` (default `3`) times. On exceeding the cap, do **not** continue; emit `[product] PO_DECISION kind=release_decision decision=no_go rationale=integration_cycle_cap_hit cap=<n>`, append a release-blocking entry to `.scrum/po/attention.md` enumerating remaining defects, materialise each remaining defect as a `known-issues` draft PBI in `.scrum/backlog.json`, then halt the skill in a safe parked state for human morning review. |
| 10. Release decision          | "User confirms release-ready" → `[product] PO_DECISION_REQUEST kind=release_decision options=[go,no_go] recommendation=<...>`. `decision=go` is mechanically gated by `append-po-decision.sh` (requires `.scrum/test-results.json.overall_status ∈ {passed, passed_with_skips}`); a rubber-stamp `go` without passing results is rejected by the wrapper.                                  |
| 10a. CLAUDE.md regeneration   | The "warn user before overwriting" prompt is non-interactive in agent mode: if `CLAUDE.md` exists, the Developer first copies it to `.scrum/po/claude-md-backup-<UTC-ISO8601>.md` (writable PO-scoped path), then regenerates. The backup path is recorded in the `release_decision=go` decision's `--evidence`. No human wait.                                                            |

The "user confirms" / "user confirmation" / "ask user" phrases in the
Steps below are mode-agnostic: under `po_mode=agent` they resolve to
`PO_DECISION_REQUEST` per the table above, not to human prompts. SM
never blocks on `read` from stdin in this mode.

## Steps

1. state.json → phase: "integration_sprint":
   ```bash
   .scrum/scripts/update-state-phase.sh integration_sprint
   ```
2. Spawn 1-2 Developer teammates for testing (spawn-teammates skill)
3. Delegate smoke-test skill→**wait for completion** (do NOT proceed early)
4. Delegate **design-completeness-check** skill (same testing Developer
   teammate(s))→**wait for completion**. The skill derives a functional
   inventory from the enabled design specs
   (`docs/design/catalog-config.json` + `docs/design/specs/**`),
   verifies each item against the running integrated system at
   integration-test granularity, appends a `design_completeness`
   TestCategory to `.scrum/test-results.json`, and recomputes
   `overall_status`. Runs even when smoke-test reported
   `passed_with_skips` (skips are not failures). Recorded as skipped
   with reason `no enabled design specs` when no specs are enabled.
5. **Quality gate — test-results.json** (combined: smoke-test
   categories + `design_completeness`):
   - passed→step 6
   - passed_with_skips→inform user which categories skipped + why→step 6 (note skipped areas in UAT story walkthrough preamble)
   - failed→review errors→self-review related code→present all failures→ask user for additional issues→create PBI per confirmed failure→step 9 (Development Sprint)→re-enter Integration Sprint after fix
   - `design_completeness` failures (including `missing` spec'd
     functions) follow the same failed path: present failures →
     confirmed failure → PBI → Development Sprint → re-enter
     Integration Sprint. `missing` items become implementation PBIs
     referencing the spec anchor recorded in the verification matrix.
   - **Block UAT until automated tests pass** (combined overall_status)
   - **No fix without assigned PBI**
   - **po_mode=agent**: replace "ask user for additional issues" with one `kind=defect_triage` PO_DECISION_REQUEST carrying the full failure list; PO returns priorities in a single reply (no per-failure round-trip).
6. **UAT (mandatory)** — user-story driven, verified one story at a time:
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
      Also surface `not_testable` items from the
      design-completeness matrix so the PO can probe them manually.
   c. Verify app running (re-launch if stopped)→tell user access point.
   d. Walk stories **one at a time**: present the story + its
      verification scenario steps → user performs/observes → ask
      "works as expected?" → wait → record verdict + feedback in
      the inventory → next story. **Never** present multiple
      stories in one prompt.
   e. Record results→failed stories go to step 7.
   - **po_mode=agent**: skip 6a–e. SM invokes `po-acceptance` (mode=uat). The PO builds the same user-story inventory `.scrum/po/uat-stories-<sprint-id>.md` itself (derived from `docs/requirements.md`, cross-checked against the `docs/product/vision.md` release-criteria section) and verifies each story by runnable command, returning one `kind=uat_item` decision per story. `unverifiable` becomes `fail` unless `waive` with rationale (per `po-acceptance`).
7. **Defect collection (no fixing yet)**:
   a. Present failed stories (US-NNN + feedback) → "any other
      issues?" → repeat until user says "that's all".
   b. SM self-review: related code, adjacent features, shared components→propose additional fixes→user confirmation
   c. Consolidate full defect list→user confirms complete
   - **po_mode=agent**: collapse 7a–c into the single `PO_ACCEPTANCE_REPORT` returned by `po-acceptance` (mode=uat). The PO appends its own self-review of adjacent features and terminates with `FEEDBACK_COMPLETE`. No iterative loop.
8. **Defect→PBI**: Each confirmed defect→backlog.json PBI (status: draft→immediately refined, acceptance_criteria: expected vs actual, priority by severity). **No fix without assigned PBI — non-negotiable**
9. **Return to Development Sprint**: state.json → phase: "backlog_created"→normal Sprint cycle (Refinement→Planning→Design→Implementation→Review→Sprint Review→Retrospective)→after fix Sprint→re-evaluate Product Goal→re-enter Integration Sprint:
   ```bash
   .scrum/scripts/update-state-phase.sh backlog_created
   ```
   - **po_mode=agent**: this re-entry counts against `.scrum/config.json.po.max_integration_cycles` (default `3`). On cap-hit, do not return to development; instead emit `kind=release_decision decision=no_go rationale=integration_cycle_cap_hit cap=<n>`, append a `release-blocking: yes` entry to `.scrum/po/attention.md` listing every remaining defect, materialise each remaining defect as a `known-issues` draft PBI in `.scrum/backlog.json`, then halt the skill in a parked safe state for human morning review.
10. **Release decision**: User confirms release-ready→
    a. **CLAUDE.md regeneration**: Delegate Developer→fully regenerate `CLAUDE.md` at project root:
       - **Directory structure** (current state, scanned from filesystem)
       - **System architecture overview** (components, data flow, key integrations)
       - **Tech stack + key conventions** (commands, code style, status flows)
       - Target ~200 lines (目安). Exceeded→warn user, do not block
       - **Full regeneration**: prior content overwritten. Warn user before write if existing CLAUDE.md has content not derivable from requirements.md/code (manual edits at risk)
    b. state.json phase: "complete":
       ```bash
       .scrum/scripts/update-state-phase.sh complete
       ```
    Not ready→identify remaining work→Development Sprint
    - **po_mode=agent**: `[product] PO_DECISION_REQUEST kind=release_decision options=[go,no_go] recommendation=<...>`. `decision=go` is gated by `append-po-decision.sh` (rejects unless `.scrum/test-results.json.overall_status ∈ {passed, passed_with_skips}`) — rubber-stamp `go` is mechanically impossible. On `go`, before regenerating CLAUDE.md the Developer copies the existing file to `.scrum/po/claude-md-backup-<UTC-ISO8601>.md` (PO-writable path) and records that backup path as `--evidence` on the `release_decision` decision; the regeneration then proceeds without a human wait. `no_go` returns to step 9 (subject to the re-entry cap above).

Ref: FR-013

## Exit Criteria

- test-results.json exists (passed or passed_with_skips)
- `design_completeness` category recorded in test-results.json
  (passed or skipped-with-reason)
- All test categories executed or skipped
- UAT user-story inventory `.scrum/po/uat-stories-<sprint-id>.md`
  exists with FR⇄US traceability appendix (uncovered-FR list empty
  or explicitly waived) and every story has a recorded verdict
  (`pass | fail | waive` + feedback)
- Release confirmed→`CLAUDE.md` regenerated + phase: "complete" OR new PBIs created
