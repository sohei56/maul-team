# claude-scrum-team Development Guidelines

## Project Structure

```text
scrum-start.sh           # Entry point — validates prereqs, launches tmux
agents/                  # Agent + 11 sub-agent definitions (top-level: scrum-master, developer; sub-agents listed in docs/contracts/sub-agents.md)
  scrum-master.md        # Team lead (Delegate mode)
  developer.md           # Developer teammate (PBI pipeline conductor)
  # Sprint-end cross-review (5-aspect parallel): requirement-conformance-reviewer, functional-quality-reviewer, security-reviewer, maintainability-reviewer, docs-consistency-reviewer
  # PBI pipeline (per Round): pbi-{designer,implementer,ut-author}, codex-{design,impl,ut}-reviewer
skills/                  # 15 Skills (Scrum ceremonies) — YAML frontmatter + Markdown, deployed to target projects via setup-user.sh
  backlog-refinement/    # Refine PBIs from coarse to sprint-ready
  change-process/        # Manage changes to frozen design docs
  cross-review/          # Sprint-end cross-cutting quality gate
  pbi-pipeline/          # PBI conductor pipeline (orchestrator + references/)
  pbi-escalation-handler/ # SM-side escalation handler
  pbi-merge/             # SM-side per-PBI merge orchestration
  install-subagents/     # Install specialist sub-agents for PBI work
  integration-sprint/    # Product-wide QA and integration testing
  requirements-sprint/   # Elicit requirements from user
  retrospective/         # Sprint retrospective ceremony
  scaffold-design-spec/  # Create design doc stubs from catalog
  smoke-test/            # Automated test execution
  spawn-teammates/       # Spawn developer teammates for sprint
  sprint-planning/       # Sprint planning and PBI assignment
  sprint-review/         # Sprint review ceremony
.claude/skills/          # Dev-only skills for THIS repo (not deployed to target projects)
  cleanup-audit/         # 8-axis multi-agent repo hygiene audit (read-only)
hooks/                   # Claude Code hooks (status/path/scrum-state/branch-ops guards, completion + quality + stop-failure gates, dashboard events, session context)
  lib/                   # Shared hook helpers (validation, logging)
dashboard/               # Textual TUI dashboard (Python)
  app.py                 # Main TUI application
scripts/                 # Setup and utility scripts
  lib/                   # Shared script helpers (prereq checks)
  setup-user.sh          # Copies agents/skills/hooks to target project
  setup-dev.sh           # Installs dev dependencies (bats, shellcheck, etc.)
  statusline.sh          # Claude Code status line script
tests/                   # Test suites
  unit/                  # Bats unit tests
  lint/                  # Bats lint tests
  integration/           # Script composition tests
  fixtures/              # Test data (JSON fixtures for validation)
docs/                    # Project documentation (requirements, architecture, data model, contracts)
docs/design/                 # Design document governance
  catalog.md             # Immutable document type reference (read-only)
  catalog-config.json    # Editable list of enabled spec IDs
.scrum/                  # Runtime state (JSON, gitignored)
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
shellcheck scrum-start.sh scripts/*.sh scripts/lib/*.sh hooks/*.sh hooks/lib/*.sh

# Lint/format Python
ruff check dashboard/
ruff format dashboard/

# Install dev dependencies
sh scripts/setup-dev.sh

# Launch the Scrum team (in target project directory)
sh /path/to/claude-scrum-team/scrum-start.sh
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
- Project workflow flow (`state.json.phase`, distinct from PBI status): `new → requirements_sprint → backlog_created → sprint_planning → pbi_pipeline_active → review → sprint_review → retrospective → sprint_planning (next Sprint) | integration_sprint → backlog_created (defect-fix loop) | complete`
- PBI development flows through the `pbi-pipeline` skill: the
  Developer is a conductor that spawns specialized sub-agents per
  Round (design → impl+UT → review). State per PBI lives at
  `.scrum/pbi/<pbi-id>/`. UT is black-box (UT author cannot read impl
  source). Termination is deterministic via composite gates
  (success/stagnation/divergence/hard cap). Coverage measured by real
  tooling (C0/C1 100% by default; partial-C1 languages declare relaxed
  threshold in `.scrum/config.json`).

## State management

`.scrum/*.json` writes go through `.scrum/scripts/*.sh` wrappers
(deployed by `setup-user.sh` from this repo's `scripts/scrum/` source).
Direct edits are blocked by `hooks/pre-tool-use-scrum-state-guard.sh`
(registered as `PreToolUse`). Schemas under
`docs/contracts/scrum-state/` are the SSOT. See
`docs/MIGRATION-scrum-state-tools.md` for the wrapper map, the
v1→v2 status migration history, and known gaps. The PBI state schema
gained worktree / merge fields (`branch`, `worktree`, `base_sha`,
`head_sha`, `paths_touched`, `ready_at`, `merged_sha`, `merged_at`,
`merge_failure`, `merge_failure_count`); the legacy `phase` field
was removed in v2, with all PBI lifecycle now driven by the 12-value
`backlog.json.items[].status` enum. Merge-failure detail is preserved
via `pbi-state.json.merge_failure.kind ∈ {conflict, artifact_missing}`
plus `escalation_reason ∈ {merge_conflict, merge_artifact_missing}`
when 3 consecutive failures flip status to `escalated`. The sprint
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
the full protocol: `--no-ff` merge, `paths_touched` verification,
SendMessage matrix for `conflict` / `artifact_missing`, and
3-strike escalation to `pbi-escalation-handler`). Quality
verification (lint/test) is performed Sprint-end by `cross-review`,
not per-PBI merge.

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
