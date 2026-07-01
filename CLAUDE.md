# claude-scrum-team Development Guidelines

## Project Structure

```text
scrum-start.sh           # Entry point — validates prereqs, launches tmux (supports --autonomous)
agents/                  # Agent + 11 sub-agent definitions (top-level: scrum-master, developer, product-owner, requirements-analyst; sub-agents listed in docs/contracts/sub-agents.md)
  scrum-master.md        # Team lead (Delegate mode)
  developer.md           # Developer teammate (PBI pipeline conductor)
  product-owner.md       # PO teammate (autonomous mode; po_mode=agent)
  requirements-analyst.md # Requirement Definition ceremony (interview + mandatory benchmark web search + requirements.md/CLAUDE.md authoring)
  # Sprint-end cross-review (5-aspect parallel): requirement-conformance-reviewer, functional-quality-reviewer, security-reviewer, maintainability-reviewer, docs-consistency-reviewer
  # PBI pipeline (per Round): pbi-{designer,implementer,ut-author}, codex-{design,impl,ut}-reviewer
skills/                  # 18 Skills (Scrum ceremonies + pipeline/merge/orchestration tooling + 1 PO acceptance + 1 brief authoring) — YAML frontmatter + Markdown, deployed to target projects via setup-user.sh
  backlog-refinement/    # Refine PBIs from coarse to sprint-ready
  create-brief/          # Co-author docs/product/brief.md with the human (interactive); pre-flight for autonomous launch when no brief exists
  change-process/        # Manage changes to frozen design docs
  cross-review/          # Sprint-end cross-cutting quality gate
  design-completeness-check/ # Design-doc functional completeness at integration granularity
  pbi-pipeline/          # PBI conductor pipeline (orchestrator + references/)
  pbi-escalation-handler/ # SM-side escalation handler
  pbi-merge/             # SM-side per-PBI merge orchestration
  install-subagents/     # Install specialist sub-agents for PBI work
  integration-sprint/    # Product-wide QA and integration testing
  po-acceptance/         # PO-owned demo/UAT verification (autonomous mode)
  requirement-definition/   # Elicit requirements from user
  retrospective/         # Sprint retrospective ceremony
  scaffold-design-spec/  # Create design doc stubs from catalog
  smoke-test/            # Automated test execution
  spawn-teammates/       # Spawn developer teammates for sprint
  sprint-planning/       # Sprint planning and PBI assignment
  sprint-review/         # Sprint review ceremony
.claude/skills/          # Dev-only skills for THIS repo (not deployed to target projects)
  cleanup-audit/         # 8-axis multi-agent repo hygiene audit (read-only)
hooks/                   # Claude Code hooks (status/path/scrum-state/branch-ops guards, stop-dispatch single-entry → dashboard + completion-gate, quality + stop-failure gates, session context, autonomy lib)
  stop-dispatch.sh       # Single Stop entry: forwards payload to dashboard-event then completion-gate (replaces the 2-hook Stop registration)
  completion-gate.sh     # Stop gate; human mode dedups repeated blocks via .scrum/stop-gate.json + only blocks unresolved `escalated` in pbi_pipeline_active
  lib/                   # Shared hook helpers (validate, dashboard, autonomy, stop-gate-state)
rules/                   # Cross-cutting context auto-loaded by every Scrum agent (deployed by setup-user.sh to .claude/rules/)
  scrum-context.md       # Team map, SSOT locations, communication protocol, PO seat resolution, uncertainty handling
dashboard/               # Textual TUI dashboard (Python)
  app.py                 # Main TUI application
scripts/                 # Setup and utility scripts
  lib/                   # Shared script helpers (prereq checks)
  setup-user.sh          # Copies agents/skills/hooks/rules to target project
  setup-dev.sh           # Installs dev dependencies (bats, shellcheck, etc.)
  statusline.sh          # Claude Code status line script
  stall-watchdog.sh      # External teammate-stall monitor (non-autonomous mode); launched by scrum-start.sh, nudges SM via tmux when no activity for `stall_watchdog.idle_threshold_minutes`
  scrum/                 # SSOT state wrappers (deployed to .scrum/scripts/ by setup-user.sh)
  autonomous/            # Autonomous-PO watchdog (Ralph Loop): watchdog.sh + lib/report.sh
tests/                   # Test suites
  unit/                  # Bats unit tests
  lint/                  # Bats lint tests
  integration/           # Script composition tests
  fixtures/              # Test data (JSON fixtures for validation)
docs/                    # Project documentation (requirements, architecture, data model, contracts, autonomous-mode)
docs/design/             # Design document governance
  catalog.md             # Immutable document type reference (read-only)
  catalog-config.json    # Editable list of enabled spec IDs
.scrum/                  # Runtime state (JSON, gitignored). Core: state.json, sprint.json, backlog.json, dashboard.json, communications.json, pbi/, plus runtime.json (tmux session + sm_pane_id + stall_watchdog_pid) and stop-gate.json (Stop-block dedup ledger, human mode). Autonomous mode also adds autonomy.json + po/{decisions.json,acceptance/,attention.md} + reports/.
```

## Technologies

- **Shell**: Bash 3.2+ (macOS/Linux compatible)
- **Python**: 3.9+ with Textual 8.x (TUI), watchdog (filesystem monitoring)
- **Agents/Skills**: Markdown with YAML frontmatter
- **State**: JSON files in `.scrum/` directory
- **CLI**: Claude Code with Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)

## Commands

```bash
# Run tests
bats tests/unit/ tests/lint/

# Lint shell scripts
shellcheck scrum-start.sh scripts/*.sh scripts/lib/*.sh scripts/scrum/*.sh scripts/scrum/lib/*.sh scripts/autonomous/*.sh scripts/autonomous/lib/*.sh hooks/*.sh hooks/lib/*.sh

# Lint/format Python
ruff check dashboard/
ruff format dashboard/

# Install dev dependencies
sh scripts/setup-dev.sh

# Launch the Scrum team (in target project directory)
sh /path/to/claude-scrum-team/scrum-start.sh

# Launch in autonomous-PO mode (Ralph Loop; see docs/autonomous-mode.md)
sh /path/to/claude-scrum-team/scrum-start.sh --autonomous --brief docs/product/brief.md --max-sprints 3
```

## Code Style

- **Shell**: POSIX-compatible Bash 3.2+, `set -euo pipefail`, shellcheck clean
- **Python**: Ruff-formatted, type hints, 4-space indent
- **Markdown**: 2-space indent for YAML frontmatter, 80-char line width for prose
- **JSON**: 2-space indent
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`)

## Key Conventions

- Scrum Master agent operates in **Delegate mode** — coordinates only, never writes code
- All state persisted to `.scrum/` JSON files for resume capability
- Design documents governed by `docs/design/catalog.md` (read-only type reference) + `docs/design/catalog-config.json` (editable enabled list)
- Developer teammates named with Sprint suffix: `dev-001-s{N}`
- PBI status flow (12 values, actor-split; status is sole SSOT, pipeline `phase` removed):
  - SM-managed: `draft → refined → … → awaiting_cross_review → cross_review → done` (happy path); plus escalation recovery `escalated → in_progress_design` (retry) or `escalated → blocked → in_progress_design` (parked on external dep, then resumed)
  - Developer-managed: `in_progress_design → in_progress_impl ⇄ in_progress_pbi_review ⇄ in_progress_ut_run → in_progress_merge`
  - Full graph (including failure edges): `docs/data-model.md` § State Transitions
- Sprint status flow: `planning → active → cross_review → sprint_review → complete | failed` (`failed` is a terminal failure state allowed by `sprint.schema.json`)
- On a **new project (both modes)**, `scrum-start.sh` co-authors a product brief (`docs/product/brief.md`, create-brief skill) as an interactive pre-flight step **before** Requirement Definition — the brief anchors the interview and the Requirements Analyst reconciles any brief↔requirements conflict by amending one side (PO-seat decision). The pre-flight fires only when the brief is absent and stdin is a TTY; exiting without writing a brief aborts the launch. The brief is a pre-ceremony input, not a `state.json.phase` value.
- Project workflow flow (`state.json.phase`, distinct from PBI status): `new → requirements_sprint → backlog_created → sprint_planning → pbi_pipeline_active → review → sprint_review → retrospective → backlog_created (next Sprint) | integration_sprint → backlog_created (defect-fix loop) | complete`. The `retrospective → {backlog_created | integration_sprint | complete}` edge is chosen by a PO `sprint_continuation` decision (autonomous mode); in human mode the user drives it and `sprint-planning` accepts `phase: retrospective` directly. A rollover `backlog_created` (sprint-history non-empty) is a watchdog recycle checkpoint.
- PBI development flows through the `pbi-pipeline` skill: the
  Developer is a conductor that spawns specialized sub-agents per
  Round (design → impl+UT → review). State per PBI lives at
  `.scrum/pbi/<pbi-id>/`. During Design the `pbi-designer` runs a
  **mandatory library selection web search** (proven track record +
  use-case fit) and records only web-verified library specs into the
  `S-070` catalog type (`docs/design/specs/technology/S-070-<lib>.md`,
  one per library, committed + reusable) plus a `Library Selection`
  section in `design.md`, to prevent API-misuse defects; a stdlib-only
  PBI records an explicit stdlib-only line, and `codex-design-reviewer`
  gates on the section's presence + backing specs (`missing_library_spec`).
  UT is black-box (UT author cannot read impl
  source). Termination is deterministic via composite gates
  (success/stagnation/divergence/hard cap). Coverage measured by real
  tooling (C0/C1 100% by default; partial-C1 languages declare relaxed
  threshold in `.scrum/config.json`).
- `backlog.json items[].kind ∈ {code, docs}` (default `code`) splits
  the pipeline into two paths. **kind=code** runs the full pipeline
  above. **kind=docs** (paths_touched ⊆ `**/*.md`) skips the Design
  stage and the entire UT pipeline (UT author, UT reviewer, UT Run,
  coverage gate, AC coverage gate) — only `pbi-implementer` +
  `codex-impl-reviewer` run. Sprint-end cross-review evaluates docs
  PBIs against aspect 1 (req-conformance, semantic AC check — not
  grep hit counts) and aspect 5 (docs-consistency) only; aspects
  2/3/4 reviewers are not spawned when the Sprint contains no
  kind=code PBI. `kind` is determined by `backlog-refinement` (Opus
  3-axis OR rule) and machine-enforced at ready-to-merge via
  `paths_touched ⊆ *.md`. Violation → `escalated(kind_mismatch)`.
  Stages skipped by a kind=docs PBI carry the status value `skipped`
  on `pbi-state.json {design_status, coverage_status}`; `ut_status`
  stays `pending` (the UT author/run/coverage gate are skipped, not
  the status value — `begin-impl-round.sh` resets `ut_status` to
  `pending` every impl round regardless of `kind`).
  Full flow: `skills/pbi-pipeline/SKILL.md` § Stages; rationale +
  detailed branches: `docs/superpowers/plans/2026-06-13-doc-only-pbi-flow.md`.
- `po_mode` selects the PO seat. Absent or `"human"` → the user
  (default). `"agent"` → the `product-owner` teammate (FR-023).
  Skills do not branch on mode; every "ask the user" prompt resolves
  to a `PO_DECISION_REQUEST` to the PO teammate in agent mode. See
  `rules/scrum-context.md` § PO seat resolution and
  `agents/product-owner.md`. A **non-autonomous** `scrum-start.sh`
  (no `--autonomous`) resets a leftover `po_mode=agent` in
  `.scrum/config.json` back to `"human"` at launch, so a normal
  start after a prior autonomous run does not silently re-spawn the
  PO teammate; the `.autonomous.*` tuning block is preserved.
- Autonomous mode (`scrum-start.sh --autonomous`) drives the team
  end-to-end without human input. The outer loop
  (`scripts/autonomous/watchdog.sh`) re-launches `claude -p`
  iterations, enforces safety valves (iterations / wall clock /
  Sprints / consecutive failures / per-phase Stop-block budget),
  and on API rate-limit / usage-limit / overload errors **sleeps
  until the limit resets and resumes automatically** (advertised
  reset time when parseable, else 1h default; rate-limited
  iterations do not advance the iteration counter). Cost is
  recorded in `autonomy.json` for observability but not enforced
  — spend ceilings live in the operator's Claude subscription
  plan. The watchdog writes a morning report to
  `.scrum/reports/autonomous-run-<run_id>.md`. PO decisions are
  audit-logged to `.scrum/po/decisions.json` (append-only) via
  `append-po-decision.sh`. Full operator guide: `docs/autonomous-mode.md`.
- **Stop-hook block policy diverges by mode.** The Stop hook is
  registered as a single entry (`hooks/stop-dispatch.sh`) that
  forwards the payload to `dashboard-event.sh` (best-effort) and
  then to `completion-gate.sh`. In **autonomous mode with a live
  watchdog** (`autonomy_loop_active` = `autonomy_enabled` AND
  `kill -0 watchdog_pid`) block-every-turn-end is preserved only for
  the **unbounded** in-flight inner loop (`pipeline_in_flight`, which
  always `exit 2`s); **bounded** exit-criteria-miss blocks (the
  default `block_stop` mode, incl. `escalated_unresolved`) now route
  through a per-phase circuit breaker (`autonomy_breaker_step`,
  budget `autonomous.stop_block_budget_per_phase`) and **allow exit
  (`exit 0`) once the budget trips**, so the watchdog can surface a
  stuck run instead of storming it forever (the Ralph-Loop watchdog
  contract depends on the in-flight loop; `.scrum/stop-gate.json` is
  neither read nor written). With no live watchdog the gate degrades
  to the human-mode behaviour below
  (storming a session nothing will re-launch is pointless). In
  **human mode** the gate
  fingerprint-dedups: the first block of a `<phase, situation>`
  tuple emits the verbose reason + exit 2; subsequent identical
  blocks are logged-only and allow exit. `pbi_pipeline_active` in
  human mode no longer blocks merely because PBIs are in flight —
  only unresolved `escalated` PBIs still block. Teammate liveness
  in human mode is monitored by the external
  `scripts/stall-watchdog.sh` daemon launched by `scrum-start.sh`;
  it sends a `[STALL-WATCHDOG]` nudge to the SM tmux pane when no
  filesystem activity is observed within
  `stall_watchdog.idle_threshold_minutes` (default 15).

## State management

`.scrum/*.json` writes go through `.scrum/scripts/*.sh` wrappers
(deployed by `setup-user.sh` from this repo's `scripts/scrum/` source).
Direct edits are blocked by `hooks/pre-tool-use-scrum-state-guard.sh`
(registered as `PreToolUse`). Schemas under
`docs/contracts/scrum-state/` are the SSOT. See
`docs/MIGRATION-scrum-state-tools.md` for the wrapper map, the
v1→v2 status migration history, and known gaps. Two runtime files
are written **without** a `.scrum/scripts/*.sh` wrapper because
they are hot-path bookkeeping rather than agent state:
`.scrum/stop-gate.json` is the Stop-hook dedup ledger written by
`hooks/lib/stop-gate-state.sh` (human mode only; schema
`stop-gate.schema.json`), and `.scrum/runtime.json` records the
tmux session, the SM pane id, and the stall-watchdog PID written
by `scrum-start.sh` (consumed by `scripts/stall-watchdog.sh`).
Both still match the guard's `.scrum/**/*.json` pattern, but their
writers run outside agent tool calls (hook process / launcher
script), so the guard never intercepts them; agents editing these
files via Bash are blocked as usual. The PBI state schema
gained worktree / merge fields (`branch`, `worktree`, `base_sha`,
`head_sha`, `paths_touched`, `ready_at`, `merged_sha`, `merged_at`,
`merge_failure`, `merge_failure_count`); the legacy `phase` field
was removed in v2, with all PBI lifecycle now driven by the 12-value
`backlog.json.items[].status` enum. Merge-failure detail is preserved
via `pbi-state.json.merge_failure.kind ∈ {conflict, artifact_missing,
regression}` plus `escalation_reason ∈ {merge_conflict,
merge_artifact_missing, merge_regression}` when 3 consecutive failures
flip status to `escalated`. The sprint
schema gained `base_sha` and `base_sha_captured_at`.

## Git workflow

PBI development uses one git worktree per PBI. The Scrum Master
captures `sprint.base_sha = git rev-parse HEAD` once at Sprint
start, then creates `.scrum/worktrees/<pbi-id>/` checked out at
branch `pbi/<pbi-id>` forked from that base. Each worktree has a
`.scrum -> ../../../.scrum` symlink so the SSOT is shared with the
main repo.

Developers commit only via `.scrum/scripts/commit-pbi.sh` (which
refuses if the checked-out branch is not `pbi/<id>`). On PBI
completion they run `.scrum/scripts/mark-pbi-ready-to-merge.sh`
and notify SM `[<pbi-id>] PBI_READY_TO_MERGE`.

SM merges per-PBI immediately by running the `pbi-merge` skill
(see [skills/pbi-merge/SKILL.md](skills/pbi-merge/SKILL.md) for
the full protocol: a **merge-scoped** clean check (disjoint tracked
drift is stashed across the merge and auto-restored, not a blanket
clean-tree refusal — only drift colliding with `paths_touched`
blocks), `--no-ff` merge, `paths_touched` verification, a
per-merge regression gate that runs
`.scrum/config.json.merge_regression.command` (skipped with WARN when
unset), SendMessage matrix for `conflict` / `artifact_missing` /
`regression`, and 3-strike escalation to `pbi-escalation-handler`).
The full Sprint-end lint/quality review still runs in `cross-review`.

In **deployed target projects** (registered via `setup-user.sh`), the
hook `pre-tool-use-no-branch-ops.sh` blocks raw `git checkout -b`,
`switch -c`, `branch <new>`, `merge`, `push`, `rebase` from the Bash
tool unless invoked through `.scrum/scripts/*`. The framework repo
itself does **not** register this hook (see `.claude/settings.json`)
so that framework dev work — branching, merging, pushing — proceeds
normally. The same scope applies to other PreToolUse guards shipped
with the framework (`status-gate.sh`, `pre-tool-use-path-guard.sh`):
they protect downstream target projects, not this repo. The one
exception is `pre-tool-use-scrum-state-guard.sh`, which **is**
registered in the framework's own `.claude/settings.json` because
this repo also writes to `.scrum/` during integration tests.

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
