# Requirements: AI-Powered Scrum Team

## Overview

claude-scrum-team is a shell-script-launched AI-powered Scrum development
team for Claude Code. It assembles a Scrum Master and Developer agents that
coordinate through Agent Teams to deliver iterative Development Sprints,
with the user acting as Product Owner.

## User Stories

### User Story 1 - Launch Scrum Team and Requirements Elicitation (Priority: P1)

The user runs `sh ./claude-scrum-team/scrum-start.sh` from the
CLI and an AI Scrum team is assembled automatically. The user is
guided through a Requirement Definition where a single Developer asks
structured questions to elicit product requirements. The user
responds in natural language. The Sprint concludes when both
parties agree on the requirements document. After the Requirements
Sprint, the Scrum Master creates the initial Product Backlog with
coarse-grained PBIs.

**Verification**: Run `sh ./claude-scrum-team/scrum-start.sh`,
answer the Developer's questions, and confirm the requirements
document is produced, saved, and the initial Product Backlog is
created with coarse-grained PBIs.

**Acceptance Scenarios**:

1. **Given** the shell script is available and no project is active,
   **When** the user runs `sh ./claude-scrum-team/scrum-start.sh`,
   **Then** a Scrum Master and one Developer are created, and the
   Developer begins asking requirements questions.

2. **Given** the Requirement Definition is in progress,
   **When** the user answers all questions and confirms the
   requirements,
   **Then** a requirements document is saved covering business,
   functional, and non-functional requirements.

3. **Given** the Requirement Definition is in progress,
   **When** the user provides incomplete or unclear answers,
   **Then** the Developer asks follow-up questions to clarify
   before proceeding.

4. **Given** the requirements document is complete,
   **When** the Requirement Definition concludes,
   **Then** the Scrum Master creates the initial Product Backlog
   with coarse-grained PBIs (e.g. "User Management", "Payment
   Processing", "CI/CD Setup").

5. **Given** a project already exists on disk,
   **When** the user runs `sh ./claude-scrum-team/scrum-start.sh`,
   **Then** the system resumes the existing project from the exact
   point where it was last interrupted.

---

### User Story 2 - Development Sprint Cycle (Priority: P2)

The user experiences iterative Development Sprints. The Scrum
Master proposes a Sprint Goal scoped at a granularity that is
easy for the PO to review — it does not necessarily need to be
a coherent bundle of related functionality. The user approves
or adjusts the goal in natural language. Coarse-grained PBIs are refined into
implementation-ready PBIs at Sprint Planning. Developers produce
design documents for their assigned PBIs, then implement and test
them in parallel. Cross-review occurs within the same Sprint. At
Sprint Review, the Scrum Master presents the Increment with a
summary and, only when UX changes are included, a live demo.
The user inspects results and provides feedback. A Sprint Retrospective records
improvements.

**Verification**: Start a Development Sprint after the
Requirement Definition, verify Sprint Planning refines PBIs, design
documents are produced, implementation and cross-review occur,
and Sprint Review presents the Increment to the user.

**Acceptance Scenarios**:

1. **Given** the Product Backlog exists with coarse-grained PBIs,
   **When** the Scrum Master proposes a Sprint Goal,
   **Then** the user can approve or request changes in natural
   language.

2. **Given** the user approves the Sprint Goal,
   **When** Sprint Planning occurs,
   **Then** the Scrum Master refines coarse-grained PBIs into
   implementation-ready PBIs (one per function, screen, API, or
   platform component) and assigns each to exactly one
   implementer (1 Developer = 1 PBI). No per-PBI reviewer is
   assigned — Sprint-end cross-review is performed by the
   Scrum Master via independent reviewer sub-agents (FR-009
   Layer 2).

3. **Given** Sprint Planning is complete,
   **When** the Design phase begins,
   **Then** Developers produce design documents for their assigned
   PBIs and read all existing design documents from previous
   Sprints to ensure consistency.

4. **Given** design is complete,
   **When** Developers work on assigned PBIs,
   **Then** each PBI is implemented by one Developer and reviewed
   by a different Developer within the same Sprint.

5. **Given** all PBIs in the Sprint meet the Definition of Done,
   **When** Sprint Review occurs,
   **Then** the Scrum Master presents a summary of changes and,
   only when the Increment includes UX changes, runs a live demo
   for the user.

6. **Given** the Sprint Review is complete,
   **When** the Sprint Retrospective occurs,
   **Then** improvements are recorded in a persistent log and a
   brief report is shared with the user.

7. **Given** a new Development Sprint begins,
   **When** Developers start work on assigned PBIs,
   **Then** each Developer reads the improvement log and applies
   relevant improvements to their current work.

---

### User Story 3 - Integration Sprint and Release (Priority: P3)

When the user determines the Product Goal has been achieved, the
team transitions to an Integration Sprint. This Sprint focuses on
product-wide quality assurance: integration testing, end-to-end
testing, regression testing, documentation consistency checks,
and user acceptance testing via live demo. When the user confirms
the product is release-ready, the project is complete.

**Verification**: After Development Sprints, trigger the
Integration Sprint, verify all testing categories are executed,
and confirm the user can declare the product release-ready.

**Acceptance Scenarios**:

1. **Given** the user has indicated the Product Goal is achieved,
   **When** the Integration Sprint begins,
   **Then** no new feature development occurs and all testing
   categories are executed.

2. **Given** the Integration Sprint reveals minor defects,
   **When** defects are identified,
   **Then** they are fixed within the Integration Sprint.

3. **Given** the Integration Sprint reveals major defects,
   **When** defects are identified,
   **Then** they are added to the Product Backlog and the team
   returns to Development Sprints.

4. **Given** all automated tests pass,
   **When** user acceptance testing begins,
   **Then** the team prepares the product for hands-on testing
   (e.g. launches the app locally, shares the URL or start
   command), provides the user with a guided testing flow
   covering key user workflows, and collects the user's
   feedback at each step.

5. **Given** the user has completed the guided testing flow,
   **When** the user confirms the product is release-ready,
   **Then** the project is marked complete.

---

### User Story 4 - TUI Dashboard (Priority: P4)

The user can view project progress through a rich terminal UI
dashboard. The dashboard shows three panels: Sprint Overview,
real-time PBI Progress Board, and a unified Work Log that merges
agent messages and work events into one chronological stream. The
user never needs to inspect raw files or logs to understand
project status.

**Verification**: Launch the dashboard during a Development
Sprint and verify it displays Sprint Overview, PBI Progress
Board, and Work Log, all updating in real time.

**Acceptance Scenarios**:

1. **Given** a Development Sprint is in progress,
   **When** the dashboard is displayed,
   **Then** the Sprint Overview (goal, PBIs, developers),
   PBI Progress Board, and Work Log are persistently visible
   alongside the conversation.

2. **Given** a Developer completes a PBI,
   **When** the dashboard updates,
   **Then** the PBI Progress Board reflects the completed PBI
   in real time without the user needing to refresh or invoke a
   command.

3. **Given** agents exchange messages during a Sprint (e.g. a
   Developer reports to the Scrum Master or PO via SendMessage),
   **When** the Work Log updates,
   **Then** the messages are displayed with sender, recipient,
   and timestamp, interleaved chronologically with work events.

4. **Given** a Developer modifies files during implementation,
   **When** the Work Log updates,
   **Then** the file path and change type (created, modified,
   deleted) are displayed in real time, and the user can narrow
   the view to messages-only or work-only via a filter toggle.

---

### User Story 5 - Project-Managed Specialist Sub-Agents (Priority: P5)

The system provides project-managed specialist sub-agents that
support the Scrum workflow. During Sprint-end cross-review, the
Scrum Master spawns 5 aspect-specialized reviewer sub-agents in
parallel (`requirement-conformance-reviewer`,
`functional-quality-reviewer`, `security-reviewer`,
`maintainability-reviewer`, `docs-consistency-reviewer`) over the
whole Sprint to evaluate the merged Increment along requirement
coverage, cross-PBI functional quality, security, maintainability,
and docs consistency. During implementation, Developer teammates
install PBI Pipeline sub-agents (`pbi-*`, `codex-*-reviewer`)
via the `install-subagents` Skill. All sub-agent definitions are
maintained in the project's `agents/` directory and distributed
to `.claude/agents/` by `setup-user.sh`. This happens
automatically without user involvement.

**Verification**: Observe cross-review and verify the Scrum Master
spawns reviewer sub-agents that read requirements and design docs.
Observe implementation and verify Developers use support sub-agents.

**Acceptance Scenarios**:

1. **Given** all implementers have completed their work and merged,
   **When** the Scrum Master invokes the `cross-review` Skill,
   **Then** the 5 aspect reviewer sub-agents enumerated in US5 are
   spawned in parallel and review the **whole Sprint Increment**
   against `requirements.md` and design documents. Findings tag
   PBIs by reverse-lookup against `paths_touched`.

2. **Given** an aspect-1/2/3 reviewer (req-conformance /
   functional-quality / security) returns a Critical|High Finding
   on a PBI, **When** cross-review processes the verdict, **Then**
   that PBI is reverted to `status: in_progress_impl` and the
   Developer is re-engaged to fix.

3. **Given** an aspect-4/5 reviewer (maintainability /
   docs-consistency) returns a Critical|High Finding on a PBI,
   **When** cross-review processes the verdict, **Then** the PBI
   itself proceeds to `done` and a follow-up draft PBI is appended
   to the backlog (title prefix
   `[cross-review-followup:<pbi-id>:<aspect>]`, `parent_pbi_id`
   set, dedup on title).

4. **Given** Sprint Planning assigns a PBI to a Developer teammate,
   **When** the Developer prepares for implementation,
   **Then** the Developer verifies PBI Pipeline sub-agents
   (`pbi-designer`, `pbi-implementer`, `pbi-ut-author`,
   `codex-design-reviewer`, `codex-impl-reviewer`,
   `codex-ut-reviewer`) AND cross-review reviewer sub-agents
   (`requirement-conformance-reviewer`,
   `functional-quality-reviewer`, `security-reviewer`,
   `maintainability-reviewer`, `docs-consistency-reviewer`) are
   installed under `.claude/agents/`.

---

### Edge Cases

- What happens when the user cancels a Sprint mid-implementation?
  Only the PO can cancel a Sprint. Work in progress is preserved,
  and the Scrum Master adjusts the Product Backlog accordingly.

- What happens when dependent PBIs must coexist in the same Sprint?
  The assigned implementers agree on the interface contract between
  their components before implementation begins.

- What happens when the Developer count exceeds 6?
  The Scrum Master narrows the Sprint Goal to reduce the number of
  PBIs until the Developer count is within the 1-6 range.

- What happens when a Sprint has only one PBI?
  The single Developer implements the PBI. Sprint-end cross-review
  is independent of Developer count — the Scrum Master always
  performs it via reviewer sub-agents (FR-009 Layer 2).

- What happens when cross-review finds issues that cannot be fixed
  within the Sprint?
  Issues are logged as new PBIs in the Product Backlog for a future
  Sprint.

- What happens when the improvement log grows too large?
  The log is reviewed every 3 Sprints to consolidate entries and
  archive items that are no longer relevant.

- What happens when the user wants to change requirements during
  Development Sprints?
  The Change Process is followed: Developer raises the issue,
  Scrum Master consults the user, and if approved, documents are
  updated and all Developers are notified.

- What happens when a later Sprint's design conflicts with an
  earlier Sprint's design documents?
  Developers read all existing design documents before producing
  new ones. If a conflict is discovered, the Change Process is
  followed to update the affected documents.

- What happens when the user closes Claude Code mid-Sprint?
  All project state is persisted to disk. When the user starts a
  new session, the project resumes from the exact point where it
  was interrupted.

- What happens when a Developer teammate fails or crashes
  mid-implementation?
  The Scrum Master detects the failure, reassigns the PBI to a
  new Developer teammate, and work resumes. No user intervention
  is required.

- What happens when context limits are reached mid-Sprint?
  Each Sprint starts with a fresh context. The Scrum Master loads
  state from `.scrum/` JSON files. Developer teammates receive
  only the artifacts relevant to their assigned PBIs. This
  prevents context overflow across Sprints.

## Functional Requirements

- **FR-001**: The system MUST launch a complete Scrum team when the
  user runs the shell script `scrum-start.sh`. The script launches
  a Claude Code session as the Agent Teams team lead (Scrum Master
  role), which spawns Developer teammates via Agent Teams.
  Teammates are independent Claude Code sessions that coordinate
  through a shared task list and direct messaging. If a project
  already exists on disk, running the script MUST resume the
  existing project from where it was last interrupted.

- **FR-002**: The system MUST conduct a Requirement Definition where
  a single Developer elicits requirements from the user through
  structured questions and produces a requirements document
  covering business, functional, and non-functional requirements.

- **FR-003**: The Scrum Master MUST create the initial Product
  Backlog after the Requirement Definition with coarse-grained PBIs.
  PBIs MUST be progressively refined into implementation-ready
  granularity when selected for a Sprint. The number of `refined`
  PBIs SHOULD be limited to 1-2 Sprints of capacity (6-12 PBIs)
  to avoid over-refinement of items that may change.

- **FR-004**: Each Development Sprint MUST drive each assigned PBI
  through the `pbi-pipeline` skill (the Developer is the conductor;
  it does not write code itself). The pipeline runs a Design phase
  (sub-agent `pbi-designer` authoring `.scrum/pbi/<pbi-id>/design/design.md`,
  reviewed by `codex-design-reviewer`) followed by an Impl+UT phase
  (`pbi-implementer` and `pbi-ut-author` writing source/tests in
  parallel, reviewed by `codex-impl-reviewer` and `codex-ut-reviewer`).
  The PBI design doc MUST cover: Scope, Components, Business Logic,
  Interfaces, Catalog Updates, Test Strategy Hints. catalog spec
  updates happen as a side-effect of `pbi-designer` and MUST acquire
  `flock(2)` on `.scrum/locks/catalog-<spec_id>.lock` to prevent
  parallel write contention. Developers MUST read all existing design
  documents (catalog specs in `docs/design/specs/`) for consistency.

- **FR-005**: The Scrum Master MUST propose Sprint Goals scoped at
  a granularity that is easy for the PO to review. Sprint Goals
  do not need to target coherent groups of related functionality.
  The Scrum Master MUST present them to the user for approval in
  natural language.

- **FR-006**: The system MUST assign each PBI to exactly one
  implementer (1 Developer = 1 PBI). The system MUST NOT assign
  per-PBI reviewers to Developers. Sprint-end review is owned by
  the Scrum Master and performed by independent reviewer
  sub-agents (see FR-009 Layer 2). The legacy `reviewer_id`
  field is removed from `backlog.json` items, and `assigned_work`
  no longer contains a `review` array.

- **FR-007**: The system MUST determine the Developer count per
  Sprint as min(number of refined PBIs, 6). Each Developer is
  a teammate spawned via Agent Teams by the Scrum Master (team
  lead). If the count exceeds 6, the Scrum Master MUST narrow
  the Sprint Goal.

- **FR-008**: The Scrum Master MUST avoid placing PBIs with
  dependencies on each other in the same Sprint. When unavoidable,
  implementers MUST agree on interface contracts before
  implementation begins.

- **FR-009**: Code review operates in two layers. **Layer 1
  (per-PBI, in-pipeline)**: each Round of `pbi-pipeline` spawns
  `codex-impl-reviewer` (against implementation source only) and
  `codex-ut-reviewer` (against test files + coverage report only)
  in parallel. These reviewers receive only the PBI design doc and
  their respective source set — never the opposing artifact —
  enforcing black-box UT discipline. Verdicts (PASS/FAIL with
  structured findings) feed the pipeline's deterministic termination
  gates (success / stagnation / divergence / hard cap N=5). **Layer
  2 (Sprint-end cross-review)**: after each per-PBI merge, the PBI
  is queued at `status: awaiting_cross_review`. At Sprint end the
  Scrum Master runs the `cross-review` skill which transitions each
  queued PBI to `status: cross_review` and runs static analysis
  once (Python `ruff`, Shell `shellcheck`) before spawning **5
  aspect-specialized reviewers in parallel over the whole Sprint
  (no per-PBI fan-out)**:
  `requirement-conformance-reviewer`, `functional-quality-reviewer`
  (cross-PBI seams only), `security-reviewer`,
  `maintainability-reviewer` (dead-code claims grounded in static
  analysis), and `docs-consistency-reviewer` (`docs/**` vs.
  implementation drift). Findings tag PBIs by `paths_touched`
  reverse-lookup; multi-PBI Findings are copied to each affected
  PBI digest. Per-PBI review files at
  `.scrum/pbi/<pbi-id>/{impl,ut}/review-r{last}.md` are read for
  context but NOT re-evaluated. **FAIL routing splits by aspect:**
  aspect 1/2/3 Critical|High → PBI returns to
  `status: in_progress_impl` (Developer fix loop, full 5-aspect
  re-evaluation on re-merge); aspect 4/5 Critical|High → PBI
  proceeds to `done` and a follow-up draft PBI is appended to the
  backlog with title prefix `[cross-review-followup:<pbi-id>:<aspect>]`
  and `parent_pbi_id` set (dedup by title). The Codex-fallback
  rule still applies to Layer 1 reviewers (`codex-impl-reviewer`,
  `codex-ut-reviewer`).

- **FR-010**: At Sprint Review, the Scrum Master MUST present the
  Increment with a change summary. A live demo MUST be performed
  only when the Increment includes UX changes; otherwise the
  demo is omitted.

- **FR-011**: The Scrum Master MUST report Product Backlog
  remaining scope and Product Goal achievement progress at every
  Sprint Review.

- **FR-012**: Sprint Retrospective MUST record improvements in a
  persistent log that carries across Sprints. The log MUST be
  reviewed every 3 Sprints to consolidate and archive entries.
  At the start of each subsequent Sprint, Developers MUST read
  the improvement log and apply relevant improvements to their
  work.

- **FR-013**: The system MUST conduct an Integration Sprint when
  the user indicates the Product Goal is achieved, covering
  integration testing, end-to-end testing, regression testing,
  documentation consistency checks, and user acceptance testing.
  Before user acceptance testing, the team MUST verify
  design-document functional completeness at integration-test
  granularity — every function described in the enabled design
  specs is verified against the running system, and unimplemented
  spec'd functions are treated as release-blocking defects. For
  user acceptance testing, the team MUST prepare the product for
  hands-on use (e.g. launch locally, share URL or start command),
  and MUST drive verification from a user-story inventory
  exhaustively derived from the requirements document — every
  release-relevant Functional Requirement traced to ≥1 user story,
  every story traced to ≥1 FR. Each story MUST be confirmed with
  the Product Owner **one at a time**, recording a verdict and
  feedback per story; multiple stories MUST NOT be batched in a
  single confirmation.

- **FR-014**: The system MUST provide a TUI dashboard that runs
  alongside the conversation and displays the following panels:
  (a) **Sprint Overview** — Sprint Goal, selected PBIs, assigned
  Developers, and current project workflow phase
  (`state.json.phase`, e.g. `pbi_pipeline_active`);
  (b) **Real-time PBI Progress Board** — each PBI's 12-value
  status (see Q&A 2026-02-25 below and `docs/data-model.md` §
  State Transitions: status) updated as work progresses;
  (c) **Work Log** — a single chronological stream merging
  messages exchanged between agents (Scrum Master <-> Developers,
  Developer <-> PO) and work events (files created, modified, or
  deleted by agents, status transitions, agent lifecycle), with a
  filter toggle (all / messages / work).
  The dashboard MUST update in real time as work progresses.

- **FR-015**: All user interactions MUST be in natural language.
  The user MUST NOT be required to write structured items, edit
  configuration files, or perform developer-level operations.

- **FR-016**: The system MUST follow the Change Process for any
  modifications to requirements or design documents during
  Development Sprints: Developer raises issue, Scrum Master
  consults user, user approves, documents are updated, all
  Developers are notified.

- **FR-017**: A PBI meets the Definition of Done when its
  `backlog.json.items[].status` reaches `done`. The pipeline's
  success gate (driving the PBI from `in_progress_ut_run` to
  `in_progress_merge`) requires ALL of: `codex-impl-reviewer`
  verdict PASS, `codex-ut-reviewer` verdict PASS, test failures = 0,
  test exec errors = 0, uncaught exceptions = 0, C0 coverage ≥
  `c0_threshold` (default 100%), C1 coverage ≥ `c1_threshold`
  (default 100%; the threshold may only be relaxed via
  `.scrum/config.json` for partial-C1 languages — ad-hoc relaxation
  is forbidden), and every pragma exclusion has a recorded
  justification (`reason_source != "missing"` in
  `pragma-audit-r{n}.json`). Existing tests must continue to pass
  (no regressions); linter/formatter must pass. After per-PBI merge
  succeeds the PBI sits at `awaiting_cross_review`; the Sprint-end
  `cross-review` (FR-009 Layer 2) transitions it through
  `cross_review` and PASS reaches `done`.

- **FR-018**: The system MUST be launchable via a shell script
  (`scrum-start.sh`) that the user runs from the CLI. The
  prerequisites are a working Claude Code installation and
  Python 3.9+ with the TUI dependencies (`textual`, `watchdog`)
  installed via pip. The shell script MUST check for these
  prerequisites and provide actionable error messages if any
  are missing.

- **FR-019**: The system MUST provide project-managed specialist
  sub-agents in `.claude/agents/`, distributed by `setup-user.sh`.
  Sub-agent catalog (purposes, tool sandboxes, spawning parents) in
  `docs/contracts/sub-agents.md`. The `install-subagents` skill
  verifies all PBI Pipeline sub-agents are present at PBI start;
  any missing required sub-agent BLOCKS the pipeline. Path-level
  constraints on `pbi-implementer` (no test paths) and `pbi-ut-author`
  (no impl paths) are enforced by `hooks/pre-tool-use-path-guard.sh`.

- **FR-020**: The requirements document MUST be frozen during
  Development Sprints. Design documents MUST be frozen after the
  Sprint in which they are created. Changes MUST follow the Change
  Process (FR-016).

- **FR-021**: The system MUST persist all project state as JSON
  files (one file per concern) in the `.scrum/` directory in the
  project root so that the user can close Claude Code at any point
  and resume the project in a later session. On resume, the project
  MUST continue from the exact point where it was interrupted.

- **FR-022**: If a Developer teammate fails or crashes during
  implementation, the Scrum Master MUST detect the failure,
  reassign the PBI to a new Developer teammate, and resume work
  without requiring user intervention.

- **FR-023**: The system MUST support an Autonomous PO mode in
  which a `product-owner` teammate replaces the human user as the
  Product Owner. When `.scrum/config.json.po_mode == "agent"`,
  every PO-approval point in every Scrum ceremony (Sprint Goal,
  PBI split, escalation choice, spec clarification, change
  request, demo acceptance, UAT verdict, defect triage, release
  decision, git-dirty, backlog approval, scope change) MUST be
  routed to that teammate via `[<scope>] PO_DECISION_REQUEST`,
  resolved via `[<scope>] PO_DECISION dec_id=<dec-NNNN>`, and
  persisted to `.scrum/po/decisions.json` through
  `.scrum/scripts/append-po-decision.sh`. The team MUST be drivable
  end-to-end (Requirement Definition → Development Sprints →
  Integration Sprint → release decision) without human input by
  the `scripts/autonomous/watchdog.sh` outer loop. The watchdog
  MUST enforce all of: `max_iterations`, `max_wall_clock_hours`,
  `max_sprints`, `max_consecutive_failures`,
  `stop_block_budget_per_phase`; on observed rate-limit /
  usage-limit / overload signals it MUST sleep until the
  advertised reset time (or a 1h default when no reset time is
  parseable) and resume without counting the wait toward
  `max_iterations`; and it MUST produce a morning report under
  `.scrum/reports/autonomous-run-<run_id>.md` on exit. The
  watchdog MUST NOT enforce a USD spend cap — spend ceilings
  live in the operator's Claude subscription plan, and
  `total_cost_usd` is recorded for observability only. The PO
  teammate MUST defer human-only matters (credentials, billing,
  legal/compliance, production deploy) to `.scrum/po/attention.md`
  rather than guessing, MUST NOT weaken any engineering quality
  gate (coverage thresholds, merge regression gate, path guard,
  cross-review routing), and MUST refuse `kind=release_decision`
  with `decision=go` when `.scrum/test-results.json.overall_status`
  is not `passed`/`passed_with_skips` or any
  `.scrum/po/attention.md` entry is tagged `release-blocking: yes`.
  When `po_mode` is absent or `"human"`, the system MUST behave
  bit-for-bit as before (zero behaviour change).

## Key Entities

- **Scrum Team**: The complete team consisting of the Product
  Owner (user), Scrum Master (Agent Teams team lead), and
  Developers (Agent Teams teammates). Each Developer is an
  independent Claude Code session.

- **Product Backlog**: Ordered list of PBIs representing all work
  needed to achieve the Product Goal. Managed by the Scrum Master.
  PBIs start coarse-grained and are progressively refined.

- **Product Backlog Item (PBI)**: A unit of work with a 12-state
  lifecycle split between SM-managed and Developer-managed states
  (see Q&A 2026-02-25 below for the full enum, and
  `docs/data-model.md` § PBI for the schema and transition graph).
  `escalated` is the gate-trip / merge-failure state resolved by
  SM `pbi-escalation-handler`; `blocked` is an SM-decided hold for
  external blockers. Each refined PBI produces three deliverables:
  design document, implementation, and tests. Design is completed
  and reviewed before implementation begins.

- **Sprint Backlog**: The Sprint Goal plus the set of refined PBIs
  selected for the Sprint, with assigned implementers and
  reviewers.

- **Increment**: A usable result of a Sprint that meets the
  Definition of Done.

- **Requirements Document**: The single source of truth for what
  the product must do. Produced in the Requirement Definition.

- **Design Documents**: Design knowledge base that grows
  incrementally across Sprints. Each Sprint adds design documents
  for its PBIs. Previous Sprints' documents are referenced for
  consistency.

- **Improvement Log**: Persistent record of retrospective
  improvements that carries across Sprints.

- **Project Directory (`.scrum/`)**: Root directory for Scrum runtime
  state (JSON files) and cross-review results, located in the user's
  project root. Design documents are governed separately by
  `docs/design/catalog.md`.

- **Product Goal**: The desired future state of the product,
  defined and owned by the user.

- **Sprint Goal**: An objective for a Sprint scoped at a granularity
  that is easy for the PO to review, proposed by the Scrum Master
  and approved by the user. Does not need to target coherent groups
  of related functionality.

## Success Criteria

- **SC-001**: The user can go from zero to a running Scrum team
  with a single shell command (`sh ./claude-scrum-team/scrum-start.sh`)
  after installing prerequisites (Claude Code, Python 3.9+, TUI
  packages). The script checks prerequisites and provides actionable
  error messages if any are missing.

- **SC-002**: The Requirement Definition produces a complete
  requirements document through natural language conversation
  alone — the user never edits structured files.

- **SC-003**: Every Development Sprint produces at least one
  Increment that meets the Definition of Done, including
  Sprint-end cross-review by 5 aspect-specialized reviewer
  sub-agents (`requirement-conformance-reviewer`,
  `functional-quality-reviewer`, `security-reviewer`,
  `maintainability-reviewer`, `docs-consistency-reviewer`) spawned
  in parallel by the Scrum Master.

- **SC-004**: The user can understand project status at any time
  through the TUI dashboard without inspecting code, logs, or
  internal files.

- **SC-005**: The user interacts exclusively in natural language
  across all Scrum events — no structured input, configuration
  editing, or developer-level operations are required.

- **SC-006**: The Integration Sprint catches defects that
  individual Sprint testing missed, as verified by integration,
  end-to-end, and regression test results.

- **SC-007**: The system operates as a shell-script-launched tool
  with minimal dependencies: Claude Code and Python 3.9+ with
  TUI packages (`textual`, `watchdog`) installed via pip.

- **SC-008**: Sprint Retrospective improvements demonstrably
  carry forward — improvements logged in Sprint N are reflected
  in team behavior in subsequent Sprints.

- **SC-009**: Design documents produced in later Sprints are
  consistent with those from earlier Sprints, as verified during
  the Integration Sprint documentation consistency check.

## Assumptions

- Claude Code is installed and available on the user's PATH.
  Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) is set
  process-scoped by `scrum-start.sh` — users do NOT need to export
  it globally. Agent Teams is an experimental feature as of
  February 2026.
- Specialist sub-agents are project-managed in the `agents/`
  directory and distributed by `setup-user.sh`. No external catalog
  dependency. The full catalog (cross-review + PBI pipeline) is in
  `docs/contracts/sub-agents.md`.
- The user's environment supports TUI rendering (standard terminal
  emulator with basic ANSI support).
- Python 3.9+ is installed and available on the user's PATH (TUI
  dependencies covered by SC-007).
- Agent Teams can be re-created per Sprint without significant
  setup overhead, as stated in the Claude Code Agent Teams
  documentation. The Scrum Master (team lead) session persists
  across Sprints; Developer teammates are spawned per Sprint.
- The user clones or downloads the claude-scrum-team repository
  and runs the shell script from within or alongside their
  project directory.

## Out of Scope

- Web-based dashboard
- Multi-user / multi-PO support
- Integration with external project management tools
- Custom agent definitions by users (project-managed sub-agents
  are provided instead)
- Multiple Scrum Teams working on the same product

## Clarifications

### 2026-04-12

- Q: How does cross-review work now that it uses independent sub-agents instead of peer Developers? A: The Scrum Master invokes the `cross-review` Skill, which runs static analysis once and then spawns the 5 aspect-specialized sub-agents enumerated in US5 in parallel via the Task tool. Each reviews the **whole Sprint Increment**, not per-PBI; Findings carry PBI tags via `paths_touched` reverse-lookup. Aspect 1/2/3 FAIL reverts the PBI to `in_progress_impl`; aspect 4/5 FAIL spawns a follow-up draft PBI. This replaces the earlier model where Developer teammates reviewed each other's code, and supersedes the 2026-04-12 Codex-CLI-based single `codex-code-reviewer` design (the Codex-CLI cross-model review remains in Layer 1 per-PBI via `codex-impl-reviewer` / `codex-ut-reviewer`). FR-009 and FR-019 updated accordingly.
- Q: Where do specialist sub-agents come from? A: All sub-agents are project-managed in `agents/` and distributed by `setup-user.sh`. The external awesome-claude-code-subagents catalog dependency was removed. FR-019 and User Story 5 updated.

### 2026-02-26

- Q: Should external dependencies be allowed for the TUI dashboard? A: Yes — Python 3.9+ with `textual` and `watchdog` packages are allowed as TUI dependencies. FR-018 revised to permit this. The dashboard must display three panels: Sprint Overview, PBI Progress Board, and Work Log (history: 2026-06-12 merged the former Communication Log and File Change Log panels into a single panel originally named "Team Log"; renamed to "Work Log" in 6996cf6).
- Q: Should the awesome-claude-code-subagents catalog be installed into `.claude/skills/` instead of `.claude/agents/`? A: No — catalog entries are subagent definition files (`.md` with subagent YAML frontmatter: `tools`, `model`), not Skill format. They require context isolation, model routing, and tool sandboxing that only subagents provide. Keep `.claude/agents/` as the installation target.

### 2026-02-25

- Q: What is the agent orchestration model? A: Agent Teams — the shell script launches one Claude Code session as the team lead (Scrum Master), which spawns Developer teammates via Agent Teams. Each teammate is an independent Claude Code session coordinating through a shared task list and direct messaging.
- Q: Where are project artifacts stored on disk? A: A `.scrum/` directory in the project root with flat JSON files (one file per concern: `state.json`, `backlog.json`, `sprint.json`, etc.) and a `reviews/` subdirectory. Design documents live separately under `docs/design/specs/{category}/`, governed by `docs/design/catalog.md`.
- Q: What serialization format for state files? A: JSON — one file per concern (e.g., `state.json`, `backlog.json`, `improvements.json`).
- Q: How are cross-Sprint context limits managed? A: Fresh context per Sprint — the Scrum Master (team lead) reads state files from disk at Sprint start; Developer teammates receive only their assigned artifacts (PBI, relevant design docs, requirements).
- Q: What are the explicit PBI lifecycle states? A: 12 states (v2 schema), actor-split — see `docs/data-model.md` § State Transitions for the canonical enum list and ASCII transition graph. The legacy 6-state model (`draft → refined → in_progress → review → done | blocked`) was replaced when the `pbi-state.json.phase` field was removed; status is the sole SSOT.
- Q: Can Agent Teams teammates use specialist sub-agents from the catalog? A: Yes — teammates are full Claude Code sessions that load `.claude/agents/` automatically. They install sub-agent `.md` files from the catalog and use them via the Task tool. This is distinct from Agent Teams itself: teammates coordinate via shared task list and messaging, while sub-agents are ephemeral workers within a teammate's session.

### 2026-02-21

- Q: Can the user close Claude Code mid-Sprint and resume later? A: Full resume — all project state is persisted to disk and the project resumes on the next session.
- Q: What happens if the shell script is run when a project already exists? A: Auto-resume — the script resumes the existing project automatically.
- Q: How does the user access the TUI dashboard during a Sprint? A: Always visible — the dashboard is shown persistently alongside the conversation.
- Q: What happens if a Developer agent fails mid-implementation? A: Auto-recover — the Scrum Master detects the failure, reassigns the PBI to a new Developer agent, and work resumes.
