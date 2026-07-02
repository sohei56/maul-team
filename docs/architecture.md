# Architecture: AI-Powered Scrum Team

## Overview

This document records the nine key architecture decisions (R1-R9) that
shape the claude-scrum-team system. R1 establishes Agent Teams with
Delegate mode as the orchestration model. R2-R3 define the TUI dashboard
and testing strategy. R4-R5 cover state persistence and the shell script
entry point. R6-R7 introduce Skills for ceremony execution and Hooks for
Sprint cycle enforcement. R8 governs design documents via the catalog
system. R9 decides on sub-agent installation for specialist capabilities.

## R1: Agent Orchestration — Claude Code Agent Teams in Delegate Mode

### Decision
Use Claude Code's `--agent <name>` flag to launch the Scrum Master as the
main thread **in Delegate mode**. Delegate mode restricts the team lead to
coordination-only operations — it cannot write code, run tests, or perform
implementation work. It can only manage tasks, communicate with teammates,
and review their output. The Scrum Master spawns Developer teammates via
Agent Teams using the `spawn-teammates` Skill (R6) for reproducibility.

### Rationale
- `--agent scrum-master` promotes `agents/scrum-master.md` as the main
  session, replacing the default system prompt.
- **Delegate mode** enforces separation of concerns: the Scrum Master
  orchestrates only, never implements. The `scrum-master.md` agent
  definition MUST include an explicit delegate mode instruction.
  Also toggleable at runtime via **Shift+Tab**.
- Teammate creation uses the `spawn-teammates` Skill (R6) for
  reproducibility across Sprints.
- Each teammate is an independent Claude Code session with its own
  context window, coordinating via shared task list and messaging.
- Agent definitions are copied to project-local `.claude/agents/` only.
  Global `~/.claude/agents/` is NEVER modified.

### Alternatives Considered
- **`--agents '{json}'`**: Rejected — definitions are complex Markdown
  that doesn't serialize well to CLI JSON.
- **Headless mode (`claude -p`)**: Rejected as primary — Scrum requires
  interactive dialogue. Useful for automated testing.
- **Sub-agents only (no Agent Teams)**: Rejected — sub-agents are
  ephemeral and lack the coordination layer for parallel development.
- **No delegate mode**: Rejected — violates the facilitator principle;
  leads to the Scrum Master doing work instead of delegating.

### Key Technical Details
- Agent definition format: Markdown with YAML frontmatter.
- Agent Teams display: **in-process** (cycle with Shift+Down) or
  **split panes** (tmux/iTerm2).
- Requires: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (set process-scoped by `scrum-start.sh`; no global export needed).
- Team lead persists across Sprints; teammates are per-Sprint.

---

## R2: TUI Dashboard — Textual App with Hook-Driven Data

### Decision
Use **Textual** (Python TUI framework) as the primary dashboard with
**watchdog** for filesystem monitoring. The dashboard runs as a separate
process in a **tmux** pane alongside Claude Code. Hooks feed real-time
events to `.scrum/` JSON files that the dashboard watches.

Reference: [sinjorjob/claude-code-agent-teams-dashboard](https://github.com/sinjorjob/claude-code-agent-teams-dashboard)
(Python `rich` + `watchdog`). Our architecture uses `textual` (built on
`rich`) for a richer interactive TUI with scrollable panels.

### Rationale
- FR-014 requires four panels needing more screen space than a status line.
- **Textual** provides `DataTable` (sortable, scrollable) and `RichLog`
  (streaming) widgets, plus keyboard navigation and CSS layout.
- **watchdog** enables filesystem-event-driven updates (not polling).
- Hooks feed event data to `.scrum/` JSON; Textual watches via watchdog.

### Alternatives Considered
- **Rich + Rich Live**: Lacks scrolling and keyboard navigation.
- **Pure shell TUI**: Insufficient for four-panel scrollable layout.
- **Web dashboard** (Bun + Vue 3): Heavy deps; out of scope per spec.
- **Urwid / curses**: Dated or high dev effort for the same result.
- **Status line only**: Too limited; retained as supplementary view.

### Key Technical Details
- `scrum-start.sh` launches tmux with two panes: Claude Code (main) +
  `python dashboard/app.py` (side). Falls back to status line only.
- Three panels (FR-014): Sprint Overview, PBI Progress Board,
  Work Log (merged chronological stream of agent messages and work
  events). See [contracts/agent-interfaces.md](contracts/agent-interfaces.md) for
  widget details and source files.
- Status line (`scripts/statusline.sh`): compact 3-line supplementary
  view, always active.
- Data flow: Hooks -> `.scrum/*.json` -> watchdog -> Textual panels.
- Dependencies: Python 3.9+, `textual`, `watchdog`, tmux (optional).
- Exit codes: `0` normal, `1` CLI missing, `2` Agent Teams off,
  `3` Python/TUI missing.

---

## R3: Testing Strategy — bats-core + jq + yq (Developer-Only)

### Decision
Use **bats-core** for shell script testing, **jq** for JSON validation, and
**yq** for YAML frontmatter validation. These are **developer-only
dependencies** — end users need only Claude Code. Two setup scripts are
provided: one for end users, one for contributors.

### Rationale
- bats-core, jq, yq are industry-standard tools for Bash/JSON/YAML.
- End users need only Python 3.9+ with `textual` and `watchdog`.
- Contributors install dev dependencies via `setup-dev.sh`.

### Key Technical Details
- Developer dependencies: bats-core, bats-support + bats-assert (git
  submodules), jq, yq, ShellCheck.
- Two setup scripts:
  - `scripts/setup-user.sh` — validates Claude Code + Agent Teams, copies
    agent definitions, configures status line. No dev deps.
  - `scripts/setup-dev.sh` — installs bats-core, jq, yq, ShellCheck,
    initializes git submodules.
- Test structure:
  ```
  tests/
  ├── unit/                    # Shell script function tests
  ├── lint/                    # Agent definition YAML validation
  ├── integration/             # Script-to-script composition
  │   └── agent-smoke.bats    # claude -p end-to-end (manual)
  ├── fixtures/                # Test data
  └── test_helper/             # bats-support, bats-assert
  ```

---

## R4: State Persistence — JSON in `.scrum/`

### Decision
All project state persists as JSON files (one file per concern) in a
`.scrum/` directory in the user's project root.

### Rationale
- JSON is human-readable, parsed by jq and Claude Code agents natively.
- One file per concern prevents lock contention with multiple agents.
- `.scrum/` is gitignored (runtime state, not committed).

### Key Technical Details
- State files: `state.json`, `backlog.json`, `sprint.json`,
  `improvements.json`, `communications.json`, `dashboard.json`
- Subdirectories: `.scrum/reviews/` (cross-review results)
- Requirements doc: `docs/requirements.md` (committed to repo, not
  runtime state — frozen during Development Sprints per FR-020,
  changes via Change Process FR-016)
- Design documents: `docs/design/specs/{category}/` (governed by `docs/design/catalog.md`)
- The Scrum Master reads state at Sprint start (fresh context per Sprint).
- Developer teammates receive only their assigned artifacts.

---

## R5: Shell Script Entry Point

### Decision
`scrum-start.sh` is the single entry point. It detects existing state,
installs agent definitions to the project-local `.claude/agents/` only,
configures the status line, and launches Claude Code with the Scrum Master
agent.

### Rationale
- Single command startup (FR-018, SC-001). Handles new and resume.
- Agent definitions copied to project-local `.claude/agents/` only.

### Key Technical Details
- Script flow:
  1. Validate Claude Code is installed. Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` process-scoped (no user action needed; exit code 2 is reserved but not triggered).
  2. Validate Python 3.9+ and TUI packages (`textual`, `watchdog`).
  3. Determine user's project root (current directory).
  4. Check for existing `.scrum/` directory (resume vs. new project).
  5. Copy agent definitions to `<project>/.claude/agents/` (local only).
  6. Configure status line in `<project>/.claude/settings.json` (merge).
  7. If tmux available: create tmux session with two panes —
     main pane for Claude Code, side pane for
     `python "$SCRIPT_DIR/dashboard/app.py"` (resolved relative to
     `scrum-start.sh`'s own location, not the user's working directory).
  8. Launch: `claude --agent scrum-master` (in main/only pane).
  9. On resume: append system prompt includes current state summary.
- All stderr messages MUST be actionable: clearly state what went wrong
  and what to do next.
- Exit codes: `0` (normal), `1` (Claude Code not found), `2` (reserved —
  Agent Teams is set process-scoped by `scrum-start.sh`), `3` (Python 3.9+
  or TUI packages not found). See R2 for full exit code table.

**Python / pip Guidance** (`setup-user.sh`):
- MUST check for `pip`/`pip3`. If missing, print actionable guidance
  (ensurepip, system package manager, venv example).
- MUST NOT create venvs automatically — only provide guidance.
- See [contracts/agent-interfaces.md](contracts/agent-interfaces.md) § setup-user.sh for full error message spec.

---

## R6: Claude Code Skills for Scrum Ceremonies

### Decision
Extract routine Scrum ceremonies and phase workflows into **Claude Code
Skills** under `.claude/skills/`. Each Skill encapsulates a ceremony's
steps and requires only variables (Sprint number, PBI list, etc.) to
execute.

### Rationale
- Skills are Markdown files with YAML frontmatter in
  `.claude/skills/<name>/SKILL.md`. Support variable substitution,
  dynamic context injection, and `allowed-tools` restriction.
- Preloaded via `skills:` field in agent definitions. Use
  `disable-model-invocation: true` to fire only on explicit invocation.

### Key Technical Details
- Skill directory structure:
  ```
  .claude/skills/
    sprint-planning/SKILL.md         # Sprint Planning ceremony
    spawn-teammates/SKILL.md         # Teammate creation (reproducible)
    install-subagents/SKILL.md       # Sub-agent selection from catalog (reproducible)
    pbi-pipeline/SKILL.md            # Per-PBI multi-sub-agent pipeline (R10)
    pbi-merge/SKILL.md               # SM-side per-PBI merge orchestration
    pbi-escalation-handler/SKILL.md  # SM-side pbi-pipeline escalation handler
    cross-review/SKILL.md            # Sprint-end cross-cutting quality gate
    sprint-review/SKILL.md           # Sprint Review ceremony
    retrospective/SKILL.md           # Retrospective ceremony
    requirement-definition/SKILL.md  # Requirement Definition ceremony
    integration-sprint/SKILL.md      # Integration Sprint ceremony
    backlog-refinement/SKILL.md      # PBI refinement process
    change-process/SKILL.md          # FR-016 Change Process
    scaffold-design-spec/SKILL.md    # Template stub creation on catalog enable
    smoke-test/SKILL.md              # Automated test execution and HTTP smoke testing
  ```

- **Mandatory Inputs/Outputs section**: Every Skill MUST declare, at the
  top of the SKILL.md body (immediately after the YAML frontmatter),
  an `## Inputs` and `## Outputs` section. This makes each Skill's
  data dependencies and side effects explicit and testable.
  ```markdown
  ## Inputs (required state)
  - `state.json` -> `phase` (must be `sprint_planning`; project-level workflow)
  - `backlog.json` -> `items[]` (PBIs with `status: refined`)
  - `sprint.json` -> `id`, `goal` (Sprint PBI membership derived from `backlog.items[]` where `sprint_id == sprint.id`)

  ## Outputs (files/keys updated)
  - `sprint.json` -> `developers[]` (populated with spawned teammates)
  - `state.json` -> `phase` (transitions to `pbi_pipeline_active`)
  - `backlog.json` -> `items[].implementer_id`, `items[].status` (assigned PBIs flip to `in_progress_design`)
  ```

- Each Skill declares Inputs, Outputs, preconditions, steps, exit
  criteria, and variables. See [contracts/agent-interfaces.md](contracts/agent-interfaces.md) § Skill Inputs/Outputs
  Reference for the full I/O table.

- **`spawn-teammates`**: Reproducible teammate creation during Sprint
  Planning. Developer count = min(refined PBIs, 6). Reads `sprint.json`
  + `backlog.json`, spawns teammates with consistent naming (`dev-001-s{N}`,
  ...). Each Developer implements their assigned PBI. There is no
  reviewer assignment — Sprint-end cross-review is performed by the
  Scrum Master via independent reviewer sub-agents (FR-009 Layer 2).

- **`install-subagents`**: Verify PBI Pipeline sub-agents
  (`pbi-designer`, `pbi-implementer`, `pbi-ut-author`,
  `codex-design-reviewer`, `codex-impl-reviewer`, `codex-ut-reviewer`)
  are installed under `.claude/agents/` (FR-019). Developers invoke
  after receiving PBI assignments; missing required sub-agent → BLOCK.

- The Scrum Master preloads ceremony skills via its `skills:` frontmatter
  (see `agents/scrum-master.md`). The Developer loads `pbi-pipeline`,
  `install-subagents`, `smoke-test`, and `design-completeness-check`.
  The Requirement Definition ceremony is run by the SM plus the
  `requirements-analyst` agent, not the Developer.

### Alternatives Considered
- **Prompt-only control**: Rejected — enormous prompt, not reproducible.
- **Hardcoded scripts**: Rejected — loses interactive dialogue for
  user-facing ceremonies.

---

## R7: Sprint Cycle Control — Hooks + State Gates + Phase Skills

### Decision
Use a three-layer architecture for Sprint cycle control that goes beyond
prompt-only management:

1. **State file** (`.scrum/state.json`) as the single source of truth
2. **Hooks** for enforcement (gating tool use, blocking premature
   completion)
3. **Skills** for ceremony execution (reproducible, variable-driven)

### Rationale
- Hooks enforce rules without relying on Claude "remembering" them.
- Skills extract ceremony logic into reusable, testable units.
- Phase-specific agents further restrict tool availability per phase.

### Key Technical Details

**Layer 1 — State File**:
- `.scrum/state.json` contains the `phase` field; the canonical
  enum and transitions live in `docs/data-model.md` § ProjectState
  (a single ASCII graph + per-phase glossary).
- Phase transitions are performed by the Scrum Master via Skill execution
  (not arbitrary writes).

**Layer 2 — Hooks**:
- `SessionStart`: injects phase context via `additionalContext`.
- `PreToolUse`: gates tool usage by phase (e.g., deny `Edit` in design).
- `Stop`: verifies exit criteria before allowing completion.
- `TaskCompleted`: enforces quality gates (tests, lint) before done.
- Defined in project-local `.claude/settings.json`.

**Layer 3 — Skills**:
- Each ceremony is a Skill that follows a deterministic sequence.
- Skills update `.scrum/state.json` phase field as part of their execution.
- Skills declare `allowed-tools` to scope what tools are available during
  the ceremony.

**Optional Layer 4 — Phase-Specific Subagents**:
- Scrum Master can delegate to specialized subagents with restricted
  tool sets via `tools`, `disallowedTools`, `permissionMode` fields.

### Alternatives Considered
- **MCP server**: Clean but adds process dependency. Deferred post-MVP.
- **Prompt-only control**: Rejected — Claude forgets rules over long
  conversations.

---

## R8: Design Documents — `docs/design/catalog.md` Governance

### Decision
Design documents are governed by `docs/design/catalog.md`. No design
document may be created unless its spec type is listed and enabled in
the catalog. Design files live at `docs/design/specs/{category}/{id}-{slug}.md`.

The governance rules themselves (catalog-first, enabled = file
required, disabled = file prohibited, no undocumented specs,
category directories, immediate stub creation on enable) live in
[`docs/design/catalog.md`](design/catalog.md). The entity schema —
catalog config shape, validation rules, frontmatter contract — lives
in [`docs/data-model.md` § DesignCatalogConfig](data-model.md#entity-designcatalogconfig)
and [§ DesignDocument](data-model.md#entity-designdocument). This
section only records the architectural **decision** to use a
catalog-first model, not the rules or schema.

### Rationale
- Per-PBI documents are too granular — related PBIs share a design spec.
- **Catalog-first governance** prevents ad-hoc document proliferation.
  The Scrum Master enables catalog entries; Developers create only what
  the catalog allows.
- PBIs reference design documents via `design_doc_paths: string[]`.

### Workflow (high level)

The runtime steps (catalog edits, `scaffold-design-spec` skill, hook
enforcement under `docs/design/specs/`) are owned by the SM
ceremony skills; see `skills/scaffold-design-spec/SKILL.md` and the
PreToolUse hook for the executable contract.

### Alternatives Considered
- **Separate `.scrum/designs/catalog.md`**: Rejected — duplicates
  governance that `docs/design/catalog.md` already provides.
- **No catalog (ad-hoc creation)**: Leads to document proliferation.
- **One doc per PBI**: Too granular; redundant for related PBIs.
- **Single monolithic doc**: Unwieldy as the project grows.

---

## R9: Project-Managed Specialist Sub-Agents

### Decision
Maintain specialist sub-agents as project-managed definitions in
`agents/`, distributed to `.claude/agents/` by `setup-user.sh`. These
sub-agents handle cross-review (code quality + security) and developer
support (TDD guidance, build error resolution). Cross-review is
performed by the Scrum Master spawning independent reviewer sub-agents,
NOT by peer Developers reviewing each other's code.

### Rationale
- **Project-managed over external catalog**: The original design (R9-v1)
  relied on the awesome-claude-code-subagents external catalog. This was
  replaced because: (a) external catalog availability is unpredictable,
  (b) agent definitions need project-specific customization (e.g.,
  reading `docs/requirements.md` and design docs during review), and
  (c) fewer moving parts improves reliability.
- **Independent reviewer sub-agents over peer review**: Developer peer
  review was replaced because: (a) Developers lack cross-PBI context
  (each only sees their own assignment), (b) independent sub-agents can
  read requirements and design docs without context window pressure on
  the Developer, and (c) Codex cross-model review adds a second opinion
  from a different AI model.
- Sub-agents use the `tools` frontmatter field for tool sandboxing
  (all cross-review reviewers are read-only) and context isolation via
  the Task tool.

### Alternatives Considered
- **External catalog (awesome-claude-code-subagents)**: Original R9-v1.
  Rejected — unreliable availability, no project-specific customization.
- **Developer peer review**: Original FR-009 model. Rejected — lacks
  cross-PBI context and design-doc awareness.
- **Skills instead of agents**: Rejected — sub-agents need context
  isolation, model routing, and tool sandboxing.

### Key Technical Details
- **Sub-agent catalog**: full list, roles, and tool sandbox in
  `docs/contracts/sub-agents.md`.
- Distributed via `setup-user.sh` to `.claude/agents/`.
- Cross-review flow: Scrum Master invokes the `cross-review` skill,
  which runs a static analysis pass and then spawns 5 aspect
  reviewers in parallel via the Task tool —
  `requirement-conformance-reviewer`, `functional-quality-reviewer`,
  `security-reviewer`, `maintainability-reviewer`,
  `docs-consistency-reviewer`. Each reviewer ingests the whole Sprint;
  Findings carry PBI tags via `paths_touched` reverse-lookup.
- PBI Pipeline: the Developer conductor spawns `pbi-*` workers and
  `codex-*-reviewer` critics per Round (see R10).
- Runtime tracking: `sprint.json` → `developers[].sub_agents` records
  only actually used agents.

## R10: PBI Pipeline — Per-PBI Multi-Sub-Agent Workflow

### Decision

The Developer agent is a per-PBI pipeline conductor; it does not write
code. Per assigned PBI it spawns six specialized sub-agents (`pbi-designer`,
`codex-design-reviewer`, `pbi-implementer`, `pbi-ut-author`,
`codex-impl-reviewer`, `codex-ut-reviewer`) over multiple Rounds of design
and impl+UT phases. State flows through `.scrum/pbi/<pbi-id>/` artifacts.
Termination uses deterministic composite gates (success / stagnation /
divergence / hard cap). Coverage is measured by real tooling (C0/C1 100%
by default).

### Rationale

- **Black-box UT**: `pbi-ut-author` cannot read implementation source
  (enforced by `hooks/pre-tool-use-path-guard.sh`), so tests are written
  against the design's interfaces only.
- **Cross-model review**: Codex-based reviewers provide independent
  critical review free of in-context anchoring; Claude fallback when
  Codex CLI unavailable.
- **Deterministic gates**: Stagnation detection uses exact
  finding-signature equality across consecutive Rounds — no fuzzy
  similarity heuristics. Anthropic + Ralph + GAN-derived composite
  ensures convergence without infinite loops.
- **Real-tool coverage**: C0/C1 thresholds are evaluated against
  output from coverage.py / c8 / JaCoCo etc., not LLM estimates.

### Alternatives Considered

- **Single-session Developer (legacy)**: Rejected — no cross-model
  review, UT writer biased by impl context, no enforced coverage gate.
- **GAN-style rollback on divergence**: Deferred to future work; current
  divergence gate escalates to SM instead.
- **Heuristic stagnation (e.g. 80% finding-similarity)**: Rejected —
  arbitrary threshold; replaced with deterministic finding-signature
  equality.

### Key Technical Details

- Spec: `docs/superpowers/specs/2026-05-02-pbi-pipeline-design.md`
- Skill: `skills/pbi-pipeline/` (orchestrator SKILL.md + 8 references)
- SM-side escalation: `skills/pbi-escalation-handler/SKILL.md`
- Path enforcement hook: `hooks/pre-tool-use-path-guard.sh`
- Codex invocation: `scripts/lib/codex-invoke.sh`
- Per-PBI state: `.scrum/pbi/<pbi-id>/state.json` and
  `pipeline.log`
- Catalog write contention: 3-layer defense (sprint-planning
  pre-separation, runtime flock, mtime conflict detection).
- TUI: dashboard PBI Board reads `backlog.json.items[].status`
  (12-value SSOT) and per-PBI round counters from
  `.scrum/pbi/<pbi-id>/state.json`.
