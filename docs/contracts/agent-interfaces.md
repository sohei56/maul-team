# Agent Interface Contracts


Defines the interface contracts between agents in the system. Each agent
has inputs (what it receives), outputs (what it produces), and
responsibilities (what it owns).

---

## Agent: Scrum Master (Team Lead, Delegate Mode)

**Definition file**: `agents/scrum-master.md`
**Launch**: `claude --agent scrum-master` (in Delegate mode)
**Role**: Agent Teams team lead — coordination only
**Mode**: Delegate mode (cannot write code, run tests, or perform
  implementation work; can only manage tasks, communicate with teammates,
  and review output). Enforced via agent definition instruction +
  Shift+Tab toggle at runtime.
**Skills**: The SM preloads 13 ceremony Skills via its `skills:` field
  (see `agents/scrum-master.md`). The repo ships 18 Skills total; the
  remainder are preloaded by other agents — 4 by the Developer
  (`pbi-pipeline`, `install-subagents`, `smoke-test`,
  `integration-tests`), `po-acceptance` by the `product-owner`
  teammate (SM only invokes it indirectly by sending
  `PO_DECISION_REQUEST kind=demo_acceptance | uat_item` to the PO in
  autonomous mode), and `create-brief` by no agent (the `scrum-start.sh`
  launcher runs it as an interactive pre-flight). Note
  `requirement-definition` is preloaded by both the SM and the
  `requirements-analyst`, and `integration-tests` by both the SM (it
  orchestrates entry, spawn, and the quality gate) and the Developer
  (the testing teammate executes the test-design / stub / automation
  steps).

### Inputs
- User natural language (direct conversation)
- `.scrum/state.json` (on resume)
- `.scrum/backlog.json` (for Sprint Planning)
- `.scrum/improvements.json` (at Sprint start)
- `.scrum/sprint-history.json` (for progress reporting)
- `docs/design/catalog.md` (for Sprint Planning — determine which specs to enable)
- Developer teammate messages (via Agent Teams messaging)

### Outputs
- `.scrum/state.json` (creates and updates)
- `.scrum/backlog.json` (creates and updates PBIs)
- `.scrum/sprint.json` (creates per Sprint)
- `.scrum/sprint-history.json` (appends after Sprint completion)
- `.scrum/improvements.json` (creates and updates)
- `docs/requirements.md`, `docs/requirements-benchmark.md`, `CLAUDE.md` (delegates authorship to `requirements-analyst`; committed to repo)
- `docs/design/catalog.md` (enables entries during Sprint Planning)
- `docs/design/specs/{category}/*.md` (delegates creation to Developers)
- Developer teammate creation (via Agent Teams)
- In-conversation status updates (Sprint Planning summary, Sprint Review)

### Responsibilities

| FR | Responsibility |
|----|----------------|
| FR-001 | Launch team (spawn teammates via Agent Teams), resume from state |
| FR-002 | Orchestrate Requirement Definition: spawn single `requirements-analyst`, receive requirements + benchmark documents |
| FR-003 | Create and maintain Product Backlog; progressive refinement |
| FR-004 | Orchestrate Design phase: determine design document granularity (R8), assign Developers, ensure existing designs are read |
| FR-005 | Propose Sprint Goals (PO-reviewable scope), get user approval |
| FR-006 | Assign implementers (one per PBI). Per-PBI aspect review runs inside the pipeline (Developer-conducted Integrity stage); Sprint-end audit is owned by SM via cross-review (FR-009) — no reviewer assigned per PBI in backlog |
| FR-007 | Calculate Developer count: min(refined PBIs, 6) |
| FR-008 | Avoid dependent PBIs in same Sprint (use `depends_on_pbi_ids`) |
| FR-009 | Two-tier review. (1) Per-PBI: the Developer conductor runs the 5-aspect **Integrity stage** at each Round tail before ready-to-merge (Critical/High → revert to `in_progress_impl`, bounded by the impl_round hard cap; PASS → consolidated `.scrum/reviews/<pbi-id>-review.md`). (2) Sprint-end: SM runs `cross-review` as an **audit-only** ceremony — static analysis + the whole-repo 4-axis `codebase-audit` (spec-conformance, logic-defect, redundancy, product-security). The audit is non-blocking: Critical/High findings become next-Sprint draft PBIs; it never reverts a PBI. At ceremony end every Sprint PBI transitions `cross_review → done`. |
| FR-010 | Present Sprint Review, conditional live demo (based on `ux_change` field) |
| FR-011 | Report remaining scope and progress |
| FR-012 | Record and consolidate retrospective improvements |
| FR-013 | Orchestrate Integration Sprint: testing categories, user acceptance |
| FR-014 | Keep `.scrum/` state files accurate so dashboard renders correctly |
| FR-015 | Ensure all user interactions are in natural language |
| FR-016 | Facilitate Change Process |
| FR-017 | Verify Definition of Done via quality gates |
| FR-019 | Verify Developers installed relevant sub-agents (spot-check) |
| FR-020 | Enforce document freeze rules |
| FR-021 | Persist all state to `.scrum/` for resume capability |
| FR-022 | Detect teammate failure, reassign PBI |

### Skills Mapping

| Skill | Ceremony / Phase | Key FRs |
|-------|-----------------|---------|
| `requirement-definition` | Requirement Definition | FR-002 |
| `backlog-refinement` | PBI refinement | FR-003 |
| `sprint-planning` | Sprint Planning | FR-005, FR-006, FR-007, FR-008 |
| `spawn-teammates` | Teammate creation (reproducible) | FR-001, FR-007 |
| `install-subagents` | Sub-agent selection from catalog | FR-019 |
| `pbi-pipeline` | Per-PBI design + impl + UT pipeline (Developer-conducted) | FR-004, FR-017 |
| `pbi-merge` | SM-side per-PBI merge orchestration (immediate post-PBI merge into main with rollback / 3-strike escalation) | FR-004, FR-022 |
| `pbi-escalation-handler` | SM-side handling of pbi-pipeline escalations | FR-004, FR-017 |
| `cross-review` | Cross-review process | FR-009 |
| `sprint-review` | Sprint Review | FR-010, FR-011 |
| `retrospective` | Retrospective | FR-012 |
| `integration-tests` | Integration Tests: design-driven systematic testing | FR-013 |
| `uat-release` | UAT & Release: user-story-driven UAT + release decision | FR-013 |
| `change-process` | Change Process | FR-016 |
| `scaffold-design-spec` | Design stub creation on catalog enable | FR-004 |
| `smoke-test` | Automated test execution and HTTP smoke testing | FR-013, FR-017 |

### Skill Inputs/Outputs Reference

Every Skill declares `## Inputs` and `## Outputs` at the top of its body,
and **those sections are the SSOT** (mandatory per `docs/architecture.md`
§ R6). This table is a one-line index only — purpose + pointer; read the
named SKILL.md for the exact required state and files/keys written.

| Skill | Purpose | I/O contract (SSOT) |
|-------|---------|---------------------|
| `create-brief` | Co-author `docs/product/brief.md` (interactive pre-flight; no `.scrum/` writes) | `skills/create-brief/SKILL.md` § Inputs/Outputs |
| `requirement-definition` | Elicit requirements → requirements.md + benchmark + CLAUDE.md | `skills/requirement-definition/SKILL.md` § Inputs/Outputs |
| `backlog-refinement` | Refine draft PBIs to sprint-ready | `skills/backlog-refinement/SKILL.md` § Inputs/Outputs |
| `sprint-planning` | Plan Sprint, assign PBIs, split oversized | `skills/sprint-planning/SKILL.md` § Inputs/Outputs |
| `spawn-teammates` | Spawn Developer teammates for the Sprint | `skills/spawn-teammates/SKILL.md` § Inputs/Outputs |
| `install-subagents` | Install PBI Pipeline sub-agents from catalog | `skills/install-subagents/SKILL.md` § Inputs/Outputs |
| `pbi-pipeline` | Per-PBI design + impl + UT pipeline (Developer-conducted) | `skills/pbi-pipeline/SKILL.md` § Inputs/Outputs |
| `pbi-merge` | SM-side per-PBI merge into main (rollback / strike rule: see Skills Mapping above) | `skills/pbi-merge/SKILL.md` § Inputs/Outputs |
| `pbi-escalation-handler` | SM-side handling of pipeline escalations | `skills/pbi-escalation-handler/SKILL.md` § Inputs/Outputs |
| `cross-review` | Sprint-end audit-only ceremony (static analysis + whole-repo 4-axis `codebase-audit`; non-blocking) | `skills/cross-review/SKILL.md` § Inputs/Outputs |
| `codebase-audit` | Whole-repo 4-axis audit (embedded in cross-review; thin re-check at Integration-Sprint entry) | `skills/codebase-audit/SKILL.md` § Inputs/Outputs |
| `sprint-review` | Sprint Review ceremony | `skills/sprint-review/SKILL.md` § Inputs/Outputs |
| `retrospective` | Retrospective; consolidate improvements | `skills/retrospective/SKILL.md` § Inputs/Outputs |
| `integration-tests` | Design-driven systematic integration testing (boundary values, flow/pattern-branch coverage, external-interface stubs) | `skills/integration-tests/SKILL.md` § Inputs/Outputs |
| `uat-release` | UAT walkthrough, defect→PBI routing, and the go/no-go release decision | `skills/uat-release/SKILL.md` § Inputs/Outputs |
| `change-process` | Manage changes to frozen design docs | `skills/change-process/SKILL.md` § Inputs/Outputs |
| `scaffold-design-spec` | Create design-doc stubs from catalog | `skills/scaffold-design-spec/SKILL.md` § Inputs/Outputs |
| `smoke-test` | Automated test execution + HTTP smoke testing | `skills/smoke-test/SKILL.md` § Inputs/Outputs |
| `po-acceptance` | PO-owned demo/UAT acceptance (autonomous mode) | `skills/po-acceptance/SKILL.md` § Inputs/Outputs |

### Lifecycle
1. On new project: create `state.json` with `phase: "new"`, start Requirement Definition
2. On resume: read `state.json`, restore workflow at saved phase
3. Per Sprint: create `sprint.json`, spawn teammates, orchestrate phases
4. At Sprint end: archive sprint to history, update state, terminate teammates

---

## Agent: Developer (Teammate)

**Definition file**: `agents/developer.md`
**Launch**: Spawned by Scrum Master via Agent Teams
**Role**: Agent Teams teammate

### Inputs
- PBI assignment from Scrum Master (via Agent Teams task list)
- `docs/requirements.md` (read-only)
- `docs/design/specs/**/*.md` (read: all existing designs for consistency)
- `docs/design/catalog.md` (read: to verify enabled entries)
- `.scrum/improvements.json` (read at Sprint start)
- Project-managed PBI Pipeline sub-agents (`pbi-designer`, `pbi-implementer`, `pbi-ut-author`, `codex-design-reviewer`, `codex-impl-reviewer`, `codex-ut-reviewer`) via FR-019

### Outputs
- `docs/design/specs/{category}/*.md` (during Design phase — only for enabled catalog entries)
- Source code changes in user's project (during Implementation phase)
- Test files in user's project (during Implementation phase)
- Messages to Scrum Master (progress, issues, completion)

### Responsibilities

| FR | Responsibility |
|----|----------------|
| FR-002 | N/A for Developer — Requirement Definition (elicit requirements from user) is owned by the `requirements-analyst` agent, not the Developer |
| FR-004 | Produce design documents; read all existing designs for consistency |
| FR-012 | Read improvement log at Sprint start, apply relevant improvements |
| FR-017 | Ensure PBI meets Definition of Done |
| FR-019 | Install/verify PBI Pipeline sub-agents (`pbi-*`, `codex-*-reviewer`) from project-managed agents |

### Lifecycle
1. Spawned by Scrum Master via `spawn-teammates` Skill
2. Receives PBI assignment via Agent Teams task
3. Reads `.scrum/improvements.json`, applies relevant improvements
4. Invokes `install-subagents` Skill for support sub-agent installation (FR-019)
5. Design phase: produces design document with `revision_history` entry
6. PBI Pipeline phase: conducts the per-PBI Round loop — spawns `pbi-designer` / `codex-design-reviewer` (Design phase), then `pbi-implementer` + `pbi-ut-author` / `codex-impl-reviewer` + `codex-ut-reviewer` (Impl+UT phase). The Developer does not write code itself.
7. Terminates at Sprint end (cross-review is handled by the Scrum Master via independent reviewer sub-agents — see FR-009)

---

## Agent: Product Owner (Teammate, autonomous mode only)

**Definition file**: `agents/product-owner.md`
**Launch**: Spawned by the Scrum Master via Agent Teams when
  `.scrum/config.json.po_mode == "agent"`; re-spawned every autonomy
  iteration (see *Lifecycle* below).
**Role**: Agent Teams teammate — final decision-maker on product
  value (vision, backlog priorities, Sprint Goal approval,
  escalation rulings, demo / UAT verdicts, release decision).
**Mode**: Never writes code, tests, or design documents. Path-guard
  hook fences writes to `docs/product/**` and `.scrum/po/**`.
**Skills**: `po-acceptance` preloaded via `skills:` field.

### Inputs

- `.scrum/config.json` (`po_mode`, `po.max_clarification_rounds`)
- `docs/product/brief.md` (mandatory — YAGNI anchor)
- `docs/product/vision.md` (when present — Out-section records prior YAGNI rejections)
- `docs/requirements.md`
- `.scrum/state.json`, `.scrum/backlog.json`, `.scrum/sprint.json`
- `.scrum/po/decisions.json` (last 20 entries on respawn for dec_id watermark)
- `.scrum/po/attention.md` (human-only queue; entries tagged `release-blocking: yes` block `release_decision=go`)
- `.scrum/test-results.json` (release gate)
- SM `SendMessage` of shape `[<scope>] PO_DECISION_REQUEST kind=<kind> options=[...] recommendation=<...> <payload>`
- `requirements-analyst` `SendMessage` of shape `[req] INTERVIEW_QUESTION <question>` — **only** during the Requirement Definition

### Outputs

- `docs/product/vision.md` (created/updated during Requirement Definition; reject rationale appended to the Out section)
- `.scrum/po/decisions.json` (every decision, via `.scrum/scripts/append-po-decision.sh`; the wrapper returns the `dec-NNNN` id the PO must echo in the reply)
- `.scrum/po/acceptance/<sprint-id>/<pbi-id>.md` and `.scrum/po/uat-<sprint-id>.md` (po-acceptance transcripts; referenced as `evidence` of the matching decision)
- `.scrum/po/attention.md` (numbered entries for human-only deferrals; never blocks)
- SM / `requirements-analyst` `SendMessage`s: `PO_DECISION`,
  `PO_CLARIFY`, `PO_ACCEPTANCE_REPORT`, `[req] INTERVIEW_ANSWER` — full
  shapes and constraints in § Communication contracts below.

### Responsibilities

| FR | Responsibility |
|----|----------------|
| FR-002 | (Requirement Definition, autonomous mode) Answer the `requirements-analyst`'s `INTERVIEW_QUESTION` prompts (incl. `kind=spec_clarification` benchmark adopt/adapt/reject dispositions); expand `brief.md` into `docs/product/vision.md`. |
| FR-003 | Approve / reject backlog priorities and PBI splits via `kind=backlog_approval` and `kind=pbi_split`. |
| FR-005 | Approve / reject Sprint Goals via `kind=sprint_goal_approval` (max 2 rejections per goal — third round must approve with `rationale=PROPOSED_GOAL: <text>`). |
| FR-010 | Demo acceptance (per PBI) via `kind=demo_acceptance`. Invokes `po-acceptance` skill in `mode=demo`. |
| FR-013 | UAT verdicts via `kind=uat_item`. Invokes `po-acceptance` skill in `mode=uat`. |
| FR-016 | Approve / reject document-freeze changes via `kind=change_request`. |
| FR-017 | **MUST NOT** weaken engineering quality gates (coverage thresholds, merge regression gate, cross-review routing, path guard). Quality is owned by SM. |
| FR-023 | Drive every PO decision point that previously read "ask the user" without blocking on human input; persist every verdict to `decisions.json`; defer human-only matters to `attention.md`. |

### Lifecycle

1. SM checks `.scrum/config.json.po_mode`. If `"agent"`, spawn the
   PO teammate at the top of every session (in-process teammates
   are not durable across session restarts).
2. PO restores context by reading the files listed in *Inputs*
   above, in that order. Aborts with a notice to SM if
   `docs/product/vision.md` is missing past `backlog_created`.
3. Per request: optional `PO_CLARIFY` (bounded by the clarification
   cap in `agents/product-owner.md` § Anti-loop rules),
   then `append-po-decision.sh` → echo `dec_id` in `PO_DECISION`.
4. Acceptance flows (demo / UAT) run the `po-acceptance` skill,
   which produces transcripts + per-AC decisions + an aggregated
   `PO_ACCEPTANCE_REPORT` to SM.
5. Terminates when the session ends. Re-spawned on the next
   watchdog iteration; state recovered from `.scrum/po/`.

### Communication contracts

This table is **shape-only** — it lists directions and message
shapes. Field formats, the `<scope>` / `kind` enums, the verdict
matrix, `dec_id` rules, the clarification cap, and channel
constraints are canonical in `agents/product-owner.md`
§ Communication protocol / § Anti-loop rules.

| Direction | Message shape |
|---|---|
| SM → PO | `[<scope>] PO_DECISION_REQUEST kind=<kind> options=[...] recommendation=<...>` |
| PO → SM | `[<scope>] PO_CLARIFY <question>` |
| PO → SM | `[<scope>] PO_DECISION kind=<kind> decision=<verdict> dec_id=<dec-NNNN> rationale=<...>` |
| requirements-analyst → PO | `[req] INTERVIEW_QUESTION <question>` (Requirement Definition only) |
| PO → requirements-analyst | `[req] INTERVIEW_ANSWER <answer>` (Requirement Definition only) |
| PO → SM | `[<scope>] PO_ACCEPTANCE_REPORT mode=<demo\|uat> results=[<id>:<verdict>:<dec_id>,...]` |

Routing rules and per-mode behaviour live in
`rules/scrum-context.md` § PO seat resolution.

---

## Agent: Project-Managed Sub-Agents (via Task Tool)

**Definition files**: Project-managed in `agents/`, distributed to `.claude/agents/` by `setup-user.sh`
**Launch**: Scrum Master or Developer invokes via Task tool (`Task(subagent_type="<agent-name>")`)
**Role**: Ephemeral worker within the spawning agent's session

Full sub-agent catalog (roles, spawning parents, tool sandboxes) in
`docs/contracts/sub-agents.md`. The 5 aspect-specialized reviewers
(`requirement-conformance-reviewer`, `functional-quality-reviewer`,
`security-reviewer`, `maintainability-reviewer`,
`docs-consistency-reviewer`) are spawned **per-PBI by the Developer** at
the pipeline's Integrity stage (not Sprint-end). Sprint-end cross-review
is audit-only: 4 whole-repo `codebase-audit` axes (`spec-conformance`,
`logic-defect`, `redundancy`, `product-security`) spawned by the SM as
general-purpose `Agent` calls (not named catalog agents), driven by
`skills/codebase-audit/references/axes.md`. PBI Pipeline uses
`pbi-{designer, implementer, ut-author}` workers and `codex-{design,
impl, ut}-reviewer` critics per Round.

### Inputs
- Task description from spawning agent (via Task tool prompt)
- Project files in working directory
- `docs/requirements.md` and `docs/design/specs/**/*.md` (reviewer sub-agents)

### Outputs
- Task result returned to spawning agent
- `.scrum/reviews/<pbi-id>-review.md` — the consolidated per-PBI Integrity
  review, authored by the **Developer conductor** at the Integrity stage
  (not by the aspect reviewers themselves; they are message-based and
  have no `Write` tool)
- File modifications (developer support sub-agents, if applicable)

**Integrity-stage aspect reviewers return markdown, not the JSON
envelope.** The 5 aspect reviewers spawned at the pipeline's Integrity
stage return a `**Verdict: PASS | FAIL**` line plus a markdown Findings
list as their final assistant message — they do **not** emit the
pbi-pipeline JSON envelope. The envelope contract
(`docs/contracts/pbi-pipeline-envelope.schema.json`, whose `criterion_key`
enum is codex-reviewer-specific) remains scoped to the codex reviewers
only. The conductor parses the markdown verdicts and synthesizes its own
aggregate `.scrum/pbi/<id>/metrics/integrity-r{n}.json`, which is a
conductor-owned artifact and is **not** bound by that schema.

### Responsibilities
- Reviewer sub-agents: evaluate code against requirements and design docs, produce review reports
- Developer support sub-agents: assist with TDD and build error resolution
- Reports only to the spawning agent (no Agent Teams visibility)

### Runtime Tracking
- Sub-agent names recorded in `sprint.json` → `developers[].sub_agents`
  (only actually used agents, not candidates).

---

## System: scrum-start.sh

**File**: `scrum-start.sh` (repository root)
**Responsibility**: FR-018 (shell script launch with Python TUI prerequisites)

### Inputs
- Working directory (user's project root)
- Environment: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (set process-scoped by `scrum-start.sh`; users do NOT set this globally)

### Outputs
- Deploys the framework asset set (agents, skills, hooks, rules) into
  `<project>/.claude/` and configures the status line + hooks in
  `<project>/.claude/settings.json` (local only, NEVER `~/.claude/`).
  The authoritative deploy-set — what is copied where — is
  `scripts/setup-user.sh`; do not re-enumerate it here.
- Launches `claude --agent scrum-master`

### Exit Codes
- `0`: Claude Code session ended normally
- `1`: Claude Code not found on PATH
- `2`: Agent Teams not enabled
- `3`: Python 3.9+ or TUI dependencies (`textual`, `watchdog`) not found

### Error Messages (stderr)

All errors MUST be actionable — clearly state what went wrong and what
to do next.

| Exit Code | stderr Message |
|-----------|----------------|
| `1` | `Error: Claude Code CLI not found on PATH. Install it: https://docs.anthropic.com/en/docs/claude-code/overview` |
| `2` | (reserved — Agent Teams flag is now set process-scoped by `scrum-start.sh`) |
| `3` | (see pip/venv guidance below) |

**Exit Code 3 — detailed pip/venv guidance** (printed to stderr):
```
Error: Python TUI packages 'textual' and 'watchdog' are required.

Recommended: install in a virtual environment:
  python3 -m venv .venv
  source .venv/bin/activate   # On Windows: .venv\Scripts\activate
  pip install textual watchdog

Or install directly:
  pip install textual watchdog

If pip is not available:
  python3 -m ensurepip --upgrade   # Install pip itself
  # Or: apt install python3-pip    # Debian/Ubuntu
  # Or: brew install python3       # macOS (includes pip)
```

### Behavior
- New project: creates `.scrum/` directory, launches fresh Scrum Master session
- Resume: detects `.scrum/state.json`, appends resume context to system prompt
- tmux detected: creates tmux session with split layout (main pane for
  Claude Code, side pane for `python dashboard/app.py`)
- tmux absent: prints `Info: tmux not found — using compact status line
  dashboard. Install tmux for a richer view.` to stderr, continues with
  status line + hook events only

---

## System: Dashboard (Textual TUI + Status Line, R2)

**Responsibility**: FR-014 (persistent TUI dashboard with four panels)

### Primary: Textual TUI App (Optional, tmux)

**File**: `dashboard/app.py`

**Launch**: Started by `scrum-start.sh` in a tmux side pane (`python dashboard/app.py`)

**Dependencies**: Python 3.9+, `textual` (TUI framework), `watchdog` (filesystem monitoring)

**Inputs**:
- `.scrum/state.json` + `.scrum/sprint.json` (Sprint Overview panel)
- `.scrum/backlog.json` (PBI Progress Board panel)
- `.scrum/communications.json` + `.scrum/dashboard.json` (Work Log panel)

**Outputs**: Full-screen interactive TUI in dedicated tmux pane with three panels:

| Panel | Widget | Source File | Description |
|-------|--------|-------------|-------------|
| **(a) Sprint Overview** | `DataTable` or `Static` | `state.json` + `sprint.json` | Sprint Goal, phase, PBI count, Developer assignments |
| **(b) PBI Progress Board** | `DataTable` (sortable, colored rows) | `backlog.json` | Each PBI with status, assignee, progress indicator |
| **(c) Work Log** | `RichLog` (scrollable) | `communications.json` + `dashboard.json` | Merged chronological stream: agent messages (sender → recipient) and work events (file changes, status transitions, lifecycle). `f` cycles filter all → messages → work |

**Update Mechanism**: `watchdog` watches `.scrum/` for file changes →
panels re-read and update. Worker threads handle blocking reads.
Keyboard navigation: Tab between panels, arrow keys to scroll.

**Graceful Degradation**: Without tmux → status line only (info message).
Without Python/Textual → exit code 3 with pip guidance.

### Supplementary: statusline.sh (Mandatory)

**File**: `scripts/statusline.sh`

**Inputs**:
- Session JSON on stdin (provided by Claude Code status line system)
- `.scrum/state.json` (read from disk)
- `.scrum/backlog.json` (read from disk)
- `.scrum/sprint.json` (read from disk)
- `.scrum/dashboard.json` (read from disk)

**Outputs**:
- Multi-line ANSI-formatted text to stdout (3-5 lines)
- Each `echo` call produces one status line row

**Update Frequency**:
- Called by Claude Code after each assistant message (debounced at 300ms)
- Reads state files on each invocation (no caching)

**Output Format**:
```
Line 1: Sprint <N> "<Goal>" | Phase: <phase> | <X>/<Y> PBIs done
Line 2: Backlog: <N> items (<M> refined, <K> draft)
Line 3: Agents: SM:active Dev1:impl(PBI-7) Dev2:review(PBI-5)
```

### Hook Events: dashboard-event.sh (Mandatory)

**File**: `hooks/dashboard-event.sh`

**Triggered by**: Claude Code hooks (`PostToolUse`, `TaskCompleted`,
`TeammateIdle`, `SubagentStart`, `SubagentStop`); also invoked
indirectly on `Stop` via `hooks/stop-dispatch.sh`.

**Inputs**:
- Hook event JSON on stdin (from Claude Code)
- `.scrum/dashboard.json` (read/append — work events)
- `.scrum/communications.json` (read/append — agent messages)

**Outputs** — each happening is written to exactly one file:
- `.scrum/dashboard.json` (work events): `file_changed` (PostToolUse
  `Write|Edit|MultiEdit` branch of `dashboard-event.sh`),
  `status_transition` (Stop), `subagent_start` / `subagent_stop`,
  `task_completed`
- `.scrum/communications.json` (agent messages): `message` (SendMessage —
  sender, recipient, summary/body), `agent_spawn` (Agent tool),
  `progress_update` (TeammateIdle)

**Configuration** (in `.claude/settings.json`):
```json
{
  "hooks": {
    "PostToolUse": [{"matcher": {"tool_name": "Write|Edit|MultiEdit|Agent|SendMessage"}, "hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}],
    "TaskCompleted": [{"hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}],
    "TeammateIdle": [{"hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}]
  }
}
```

---

## System: Hooks (Sprint Cycle Control)

**Configuration**: `<project>/.claude/settings.json`
**Responsibility**: R7 Layer 2 — enforcement without relying on prompts

### Shared Hook Library
- **File**: `hooks/lib/validate.sh`
- **Provides**: `validate_json_file`, `log_hook`, `get_timestamp`, `ensure_scrum_dir`
- **Sourced by**: All hooks via `HOOK_DIR` pattern
- **Logging**: Writes timestamped entries to `.scrum/hooks.log` (auto-trimmed at 500 lines)

### SessionStart Hook
- **Script**: `hooks/session-context.sh`
- **Reads**: `.scrum/state.json`, `.scrum/sprint.json`
- **Output**: `additionalContext` with current phase, Sprint info
- **Purpose**: Inject phase context at session start
- **Validation**: Uses `validate_json_file` to verify state files before parsing

### PreToolUse Hook
- **Script**: `hooks/status-gate.sh` (renamed from `phase-gate.sh` in v2)
- **Reads**: `.scrum/state.json` current `phase` (project workflow); `.scrum/backlog.json` current PBI `status` (13-value enum); `docs/design/catalog.md`
- **Output**: `permissionDecision` (`allow`, `deny`, or `ask`)
- **Logging**: Logs all deny decisions to `.scrum/hooks.log`
- **Purpose**: Gate tool usage by project workflow phase and per-PBI status. Examples:
  - During `in_progress_design` PBI status: deny `Edit` on source/test files
  - During any `in_progress_*` status: deny `Write`/`Edit` under `docs/design/specs/`
    if target file has no enabled entry in `docs/design/catalog.md`
  - During `sprint_review` workflow phase: deny code modifications
  - During `requirements_sprint` workflow phase: deny source file creation

### Stop Hook
- **Registered entry**: `hooks/stop-dispatch.sh` — a single
  command that consumes the Stop payload once, forwards it to
  `hooks/dashboard-event.sh` (best-effort; failures swallowed),
  and then to `hooks/completion-gate.sh` (exit code propagated
  verbatim). Two-entry Stop registrations would surface as
  `"Ran 2 stop hooks"` in the session UI; the dispatcher folds
  them.
- **Gate script**: `hooks/completion-gate.sh`
- **Reads**: `.scrum/state.json`, relevant state files; in human
  mode also reads/writes `.scrum/stop-gate.json` (dedup ledger)
  via `hooks/lib/stop-gate-state.sh`.
- **Output**: exit code 2 + `reason` if exit criteria not met
- **Logging**: Logs all blocked stop attempts to `.scrum/hooks.log`
- **Purpose**: Prevent premature phase completion
- **Mode-dependent policy**:
  - *Autonomy loop active* (`autonomy_loop_active` = autonomous mode
    **and** a live watchdog, verified via `kill -0 watchdog_pid`):
    block on every Stop while the condition holds; the Ralph-Loop
    watchdog drives iteration counts and the
    `stop_block_budget_per_phase` circuit breaker. With no live
    watchdog the gate degrades to the human-mode fallback below
    (no point storming a session nothing will re-launch).
  - *Human mode*: fingerprint-dedup. First block of a
    `<phase, situation>` exits 2 with the verbose reason;
    immediate repeats are logged-only and allow exit. In
    `pbi_pipeline_active` the gate only blocks on unresolved
    `escalated` PBIs — Teammate liveness is monitored by the
    external `scripts/stall-watchdog.sh` daemon launched by
    `scrum-start.sh`.
- **Per-phase test/UAT gates** (both modes): in `integration_sprint`,
  blocks until `.scrum/test-results.json.overall_status` is `"passed"`
  or `"passed_with_skips"` (`"failed"` blocks naming the failed
  categories; `"pending"`/`"running"` blocks to wait for `smoke-test` /
  `integration-tests` to finish). In `uat_release`, blocks if
  `overall_status` has regressed back to `"failed"` since entry
  (instructing a return to `integration_sprint`), then blocks until
  `.scrum/po/uat-stories-<sprint-id>.md` exists (instructing the
  `uat-release` skill to run); once both hold, allows exit as a
  checkpoint.
- **Graceful degradation**: Allows stop (with warning) if state files are missing

### TaskCompleted Hook
- **Script**: `hooks/quality-gate.sh`
- **Reads**: PBI status, design docs, test files, lint results (scoped to git-changed files)
- **Output**: Advisory warnings to stderr (does not hard-block)
- **Purpose**: Enforce Definition of Done (FR-017) before marking tasks complete

---

## System: Setup Scripts

### setup-user.sh (End Users)
- **File**: `scripts/setup-user.sh`
- **Purpose**: Validate prerequisites and prepare project for Scrum team
- **Actions**:
  1. Validate Claude Code, Agent Teams, Python 3.9+, pip, TUI packages
  2. Copy agents/skills to `<project>/.claude/`
  3. Configure status line and hooks in `<project>/.claude/settings.json`
- **Pip/venv**: prints actionable guidance if missing (see Exit Code 3
  above). NEVER creates venvs automatically.
- **NEVER modifies** `~/.claude/` or any global settings.

### setup-dev.sh (Contributors)
- **File**: `scripts/setup-dev.sh`
- **Purpose**: Install dev dependencies (bats-core, jq, yq, ShellCheck)
- Runs `setup-user.sh` first, then installs dev deps and git submodules.
