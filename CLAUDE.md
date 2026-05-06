# claude-scrum-team Development Guidelines

## Project Structure

```text
scrum-start.sh           # Entry point — validates prereqs, launches tmux
agents/                  # Agent and sub-agent definitions
  scrum-master.md        # Team lead (Delegate mode)
  developer.md           # Developer teammate (PBI pipeline conductor)
  code-reviewer.md       # Independent code review (spawned by Scrum Master)
  security-reviewer.md   # Security vulnerability scanning (spawned by Scrum Master)
  codex-code-reviewer.md # Cross-model code review via Codex CLI (Sprint-end)
  pbi-designer.md        # PBI design author (spawned by Developer)
  pbi-implementer.md     # Implementation author — no test writes (spawned by Developer)
  pbi-ut-author.md       # Black-box test author — no impl reads (spawned by Developer)
  codex-design-reviewer.md  # Critical design review (spawned by Developer)
  codex-impl-reviewer.md    # Critical impl review — no test visibility (spawned by Developer)
  codex-ut-reviewer.md      # Critical UT review — no impl visibility (spawned by Developer)
skills/                  # 14 Ceremony Skills (YAML frontmatter + Markdown)
  backlog-refinement/    # Refine PBIs from coarse to sprint-ready
  change-process/        # Manage changes to frozen design docs
  cross-review/          # Sprint-end cross-cutting quality gate
  pbi-pipeline/          # PBI conductor pipeline (orchestrator + references/)
  pbi-escalation-handler/ # SM-side escalation handler
  install-subagents/     # Install specialist sub-agents for PBI work
  integration-sprint/    # Product-wide QA and integration testing
  requirements-sprint/   # Elicit requirements from user
  retrospective/         # Sprint retrospective ceremony
  scaffold-design-spec/  # Create design doc stubs from catalog
  smoke-test/            # Automated test execution
  spawn-teammates/       # Spawn developer teammates for sprint
  sprint-planning/       # Sprint planning and PBI assignment
  sprint-review/         # Sprint review ceremony
hooks/                   # Claude Code hooks (phase gates, completion gates, quality gates, dashboard events, session context)
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
- PBI status flow: `draft → refined → in_progress → review → done | blocked`
- Sprint status flow: `planning → active → cross_review → sprint_review → complete`
- Phase flow: `new → requirements_sprint → backlog_created → sprint_planning → pbi_pipeline_active → review → sprint_review → retrospective → sprint_planning (next Sprint) | integration_sprint → backlog_created (defect-fix loop) | complete`
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
`docs/MIGRATION-scrum-state-tools.md` for the wrapper map and known
gaps. The PBI state schema gained worktree / merge fields (`branch`,
`worktree`, `base_sha`, `head_sha`, `paths_touched`, `ready_at`,
`merged_sha`, `merged_at`, `merge_failure`, `merge_failure_count`)
and new phase enum values (`ready_to_merge`, `merged`,
`merge_conflict`, `merge_artifact_missing`, `merge_regression`).
The sprint schema gained `base_sha` and `base_sha_captured_at`.

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
which calls `.scrum/scripts/merge-pbi.sh`:
1. `--no-ff` merge into main
2. verify every `paths_touched` file is on HEAD
3. run the existing `hooks/quality-gate.sh`
4. mark `phase=merged`, mirror `merged_sha` to backlog, remove
   worktree + branch

Three failure paths roll back main and instruct the Developer to
fix on `pbi/<id>` and re-notify. Three consecutive failures of any
kind escalate via `pbi-escalation-handler`.

The hook `pre-tool-use-no-branch-ops.sh` blocks raw
`git checkout -b`, `switch -c`, `branch <new>`, `merge`, `push`,
`rebase` from the Bash tool unless invoked through
`.scrum/scripts/*`.

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
