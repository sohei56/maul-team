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
**Skills**: All 15 ceremony Skills preloaded via `skills:` field

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
- `docs/requirements.md` (delegates creation to Developer, stores result; committed to repo)
- `docs/design/catalog.md` (enables entries during Sprint Planning)
- `docs/design/specs/{category}/*.md` (delegates creation to Developers)
- Developer teammate creation (via Agent Teams)
- In-conversation status updates (Sprint Planning summary, Sprint Review)

### Responsibilities

| FR | Responsibility |
|----|----------------|
| FR-001 | Launch team (spawn teammates via Agent Teams), resume from state |
| FR-002 | Orchestrate Requirements Sprint: spawn single Developer, receive requirements document |
| FR-003 | Create and maintain Product Backlog; progressive refinement |
| FR-004 | Orchestrate Design phase: determine design document granularity (R8), assign Developers, ensure existing designs are read |
| FR-005 | Propose Sprint Goals (PO-reviewable scope), get user approval |
| FR-006 | Assign implementers (one per PBI). Sprint-end review is owned by SM via cross-review (FR-009 Layer 2) — no reviewer assigned per PBI in backlog |
| FR-007 | Calculate Developer count: min(refined PBIs, 6) |
| FR-008 | Avoid dependent PBIs in same Sprint (use `depends_on_pbi_ids`) |
| FR-009 | Orchestrate cross-review at Sprint end: SM runs static analysis once, then spawns 5 aspect reviewers in parallel over the whole Sprint — `requirement-conformance-reviewer`, `functional-quality-reviewer`, `security-reviewer`, `maintainability-reviewer`, `docs-consistency-reviewer`. Aspect 1/2/3 Critical\|High → PBI reverts to `in_progress_impl`; aspect 4/5 Critical\|High → append follow-up PBI (title prefix `[cross-review-followup:<pbi-id>:<aspect>]`). Loop until every Sprint PBI reaches `status: done`. |
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
| `requirements-sprint` | Requirements Sprint | FR-002 |
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
| `integration-sprint` | Integration Sprint | FR-013 |
| `change-process` | Change Process | FR-016 |
| `scaffold-design-spec` | Design stub creation on catalog enable | FR-004 |
| `smoke-test` | Automated test execution and HTTP smoke testing | FR-013, FR-017 |

### Skill Inputs/Outputs Reference

Every Skill MUST declare `## Inputs` and `## Outputs` at the top of its
body. Below is the reference for all 15 Skills:

| Skill | Inputs (required state) | Outputs (files/keys updated) |
|-------|------------------------|------------------------------|
| `requirements-sprint` | `state.json` → `phase: new` | `requirements.md` (created); `state.json` → `phase: requirements_sprint → backlog_created` |
| `backlog-refinement` | `backlog.json` → `items[]` with `status: draft`; `requirements.md`; count of existing `refined` PBIs (WIP check) | `backlog.json` → `items[].status: refined`, `acceptance_criteria`, `ux_change`, `design_doc_paths` (refined WIP capped at 6-12) |
| `sprint-planning` | `state.json` → `phase: backlog_created \| retrospective`; `backlog.json` → refined PBIs | `sprint.json` (created); `backlog.json` → `items[].sprint_id`, `implementer_id`; oversized PBIs split into child PBIs with `parent_pbi_id` set; `state.json` → `phase: sprint_planning` |
| `spawn-teammates` | `sprint.json` → `pbi_ids`, `developer_count`; `backlog.json` → assigned PBIs | `sprint.json` → `developers[]` (populated, `assigned_work.implement`), `status: "active"`; Agent Teams teammates spawned |
| `install-subagents` | PBI assignment (task context); project-managed agent definitions | `.claude/agents/*.md` (installed); `sprint.json` → `developers[].sub_agents` (at runtime) |
| `pbi-pipeline` | `state.json` → `phase: sprint_planning \| pbi_pipeline_active`; `sprint.json` → `developers[]`; `docs/design/catalog.md`; existing `docs/design/specs/**/*.md`; `requirements.md`; `.scrum/config.json` (coverage thresholds) | Source code; test files; `docs/design/specs/{category}/*.md` (catalog spec updates as side-effect); `.scrum/pbi/<pbi-id>/{state,design,impl,ut,metrics,feedback,pipeline.log}` (see `data-model.md` § PbiPipelineState); `backlog.json` → `items[].status` walks the Developer-managed slice (`in_progress_design → in_progress_impl ⇄ in_progress_pbi_review ⇄ in_progress_ut_run → in_progress_merge`); on termination-gate trip flips to `escalated`; `state.json` → `phase: pbi_pipeline_active` |
| `pbi-merge` | Developer notification `[<pbi-id>] PBI_READY_TO_MERGE`; `backlog.json` → `items[].status: in_progress_merge`; `.scrum/pbi/<pbi-id>/state.json` (head_sha, paths_touched, ready_at, merge_failure_count); `.scrum/sprint.json` (developer assignment) | `backlog.json` → `items[].status: in_progress_merge → awaiting_cross_review` (success) or unchanged (recoverable failure, status remains `in_progress_merge` while count < 3) or `escalated` (3rd failure); `items[].merged_sha`; `.scrum/pbi/<pbi-id>/state.json` (`merged_sha`, `merged_at`, or `merge_failure.{kind,paths}` + `merge_failure_count` ++); merge commit on `main`; worktree `.scrum/worktrees/<pbi-id>` removed on success; SendMessage to Developer with success/conflict/escalation status |
| `pbi-escalation-handler` | Developer notification `[<pbi-id>] ESCALATED reason=<reason>`; `.scrum/pbi/<pbi-id>/state.json`; `.scrum/pbi/<pbi-id>/pipeline.log` | `.scrum/pbi/<pbi-id>/escalation-resolution.md`; SM decision (retry / split / hold / human-escalate) |
| `cross-review` | `state.json` → `phase: pbi_pipeline_active \| review`; `backlog.json` → all Sprint PBIs at `status ∈ {awaiting_cross_review, escalated}` (incl. `paths_touched`); `requirements.md`; relevant `docs/design/specs/**/*.md`; `sprint.json.base_sha`; per-PBI pipeline final reviews at `.scrum/pbi/<pbi-id>/{impl,ut}/review-r{last}.md` (read for context, not re-evaluated) | `sprint.json` → `status: "cross_review"`; `.scrum/reviews/static-analysis-r{n}.json` (per-round tool output for `maintainability-reviewer`); `.scrum/reviews/sprint-impl-diff.txt` (non-doc diff for `docs-consistency-reviewer`); `.scrum/reviews/aspect-<aspect>-review.md` (5 raw aspect outputs); `.scrum/reviews/<pbi-id>-review.md` (per-PBI digest); `backlog.json` → `items[].status: awaiting_cross_review → cross_review → done` on aspect-1/2/3 PASS, or `cross_review → in_progress_impl` on aspect-1/2/3 FAIL; aspect-4/5 FAIL → new draft PBI appended (title prefix `[cross-review-followup:<pbi-id>:<aspect>]`, `parent_pbi_id` set, dedup); `items[].review_doc_path`; `state.json` → `phase: review` |
| `sprint-review` | `state.json` → `phase: review`; `sprint.json`; `backlog.json` | `sprint.json` → `status: "sprint_review"`; `sprint-history.json` → `sprints[]` (appended); `state.json` → `phase: sprint_review` |
| `retrospective` | `state.json` → `phase: sprint_review`; `improvements.json` (existing improvements and `last_consolidation_sprint`); `sprint.json` → `id` (for consolidation check) | `improvements.json` → `entries[]` (appended), stale entries archived every 3 Sprints (`status: archived`, `archived_at` set, `last_consolidation_sprint` updated); `sprint.json` → `status: "complete"`; `state.json` → `phase: retrospective` |
| `integration-sprint` | `state.json` → `phase: retrospective`; user confirmation | `.scrum/test-results.json` (structured test results from automated testing); `state.json` → `phase: integration_sprint → complete` |
| `change-process` | Frozen document path; proposed change description; user approval | Updated document with new `revision_history` entry (incl. `pbis`); `backlog.json` updates if needed |
| `scaffold-design-spec` | `docs/design/catalog.md` (newly enabled entries); `sprint.json` → `id` (current Sprint); `backlog.json` → PBI IDs for `related_pbis` | `docs/design/specs/{category}/{id}-{slug}.md` (stub files with frontmatter + placeholders) |
| `smoke-test` | `state.json` → `phase: "integration_sprint"`; `requirements.md` (endpoint/workflow discovery); project source code with existing tests | Test execution results; `.scrum/test-results.json` (populated with test category results) |

### Lifecycle
1. On new project: create `state.json` with `phase: "new"`, start Requirements Sprint
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
| FR-002 | (Requirements Sprint only) Elicit requirements from user |
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

## Agent: Project-Managed Sub-Agents (via Task Tool)

**Definition files**: Project-managed in `agents/`, distributed to `.claude/agents/` by `setup-user.sh`
**Launch**: Scrum Master or Developer invokes via Task tool (`Task(subagent_type="<agent-name>")`)
**Role**: Ephemeral worker within the spawning agent's session

Full sub-agent catalog (roles, spawning parents, tool sandboxes) in
`docs/contracts/sub-agents.md`. Cross-review uses 5 aspect-specialized
reviewers in parallel over the whole Sprint:
`requirement-conformance-reviewer`, `functional-quality-reviewer`,
`security-reviewer`, `maintainability-reviewer`,
`docs-consistency-reviewer`. PBI Pipeline uses `pbi-{designer,
implementer, ut-author}` workers and `codex-{design, impl, ut}-reviewer`
critics per Round.

### Inputs
- Task description from spawning agent (via Task tool prompt)
- Project files in working directory
- `docs/requirements.md` and `docs/design/specs/**/*.md` (reviewer sub-agents)

### Outputs
- Task result returned to spawning agent
- `.scrum/reviews/<pbi-id>-review.md` (reviewer sub-agents)
- File modifications (developer support sub-agents, if applicable)

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
- Copies `agents/*.md` to `<project>/.claude/agents/` (local only, NEVER `~/.claude/agents/`)
- Copies `skills/*/SKILL.md` to `<project>/.claude/skills/`
- Copies hook scripts to `<project>/.claude/hooks/` (or configures inline)
- Configures status line in `<project>/.claude/settings.json`
- Configures hooks in `<project>/.claude/settings.json`
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
- `.scrum/communications.json` (Communication Log panel)
- `.scrum/dashboard.json` (File Change Log panel)

**Outputs**: Full-screen interactive TUI in dedicated tmux pane with four panels:

| Panel | Widget | Source File | Description |
|-------|--------|-------------|-------------|
| **(a) Sprint Overview** | `DataTable` or `Static` | `state.json` + `sprint.json` | Sprint Goal, phase, PBI count, Developer assignments |
| **(b) PBI Progress Board** | `DataTable` (sortable, colored rows) | `backlog.json` | Each PBI with status, assignee, progress indicator |
| **(c) Communication Log** | `RichLog` (scrollable) | `communications.json` | Agent messages with sender, recipient, timestamp |
| **(d) File Change Log** | `RichLog` (scrollable) | `dashboard.json` | Files created/modified/deleted with agent ID, timestamp |

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
`TeammateIdle`, `SubagentStart`, `SubagentStop`)

**Inputs**:
- Hook event JSON on stdin (from Claude Code)
- `.scrum/dashboard.json` (read/append — file change events)
- `.scrum/communications.json` (read/append — agent messaging events)

**Outputs**:
- Appends timestamped file change events to `.scrum/dashboard.json`
- Appends agent communication messages to `.scrum/communications.json`

**Configuration** (in `.claude/settings.json`):
```json
{
  "hooks": {
    "PostToolUse": [{"matcher": {"tool_name": "Write|Edit|MultiEdit|Agent"}, "hooks": [{"type": "command", "command": "hooks/dashboard-event.sh"}]}],
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
- **Reads**: `.scrum/state.json` current `phase` (project workflow); `.scrum/backlog.json` current PBI `status` (12-value enum); `docs/design/catalog.md`
- **Output**: `permissionDecision` (`allow`, `deny`, or `ask`)
- **Logging**: Logs all deny decisions to `.scrum/hooks.log`
- **Purpose**: Gate tool usage by project workflow phase and per-PBI status. Examples:
  - During `in_progress_design` PBI status: deny `Edit` on source/test files
  - During any `in_progress_*` status: deny `Write`/`Edit` under `docs/design/specs/`
    if target file has no enabled entry in `docs/design/catalog.md`
  - During `sprint_review` workflow phase: deny code modifications
  - During `requirements_sprint` workflow phase: deny source file creation

### Stop Hook
- **Script**: `hooks/completion-gate.sh`
- **Reads**: `.scrum/state.json`, relevant state files
- **Output**: exit code 2 + `reason` if exit criteria not met
- **Logging**: Logs all blocked stop attempts to `.scrum/hooks.log`
- **Purpose**: Prevent premature phase completion
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
