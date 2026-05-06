# Quickstart: AI-Powered Scrum Team Development


## For End Users

### Prerequisites

- **Claude Code CLI** installed and on PATH
- **Python 3.9+** installed and on PATH
- **TUI dependencies**: `pip install textual watchdog`
- **tmux** (recommended) for side-by-side dashboard layout

### Getting Started

```bash
# 1. Clone the repository (once)
git clone git@github.com:sohei56/claude-scrum-team.git ~/claude-scrum-team

# 2. In your project directory:
cd /path/to/your/project

# 3. Install TUI dependencies (recommended: use a virtual environment)
python3 -m venv .venv
source .venv/bin/activate     # On Windows: .venv\Scripts\activate
pip install textual watchdog

# If pip is not available, install it first:
#   python3 -m ensurepip --upgrade
#   Or: apt install python3-pip    (Debian/Ubuntu)
#   Or: brew install python3       (macOS, includes pip)

# 4. Run the setup script (validates prerequisites, configures project)
sh ~/claude-scrum-team/scripts/setup-user.sh

# 5. Launch the Scrum team (opens tmux with Claude Code + dashboard)
sh ~/claude-scrum-team/scrum-start.sh
```

The setup script copies agent definitions and Skills to your project's
`.claude/` directory, configures the status line dashboard, and sets up
hooks. It NEVER modifies your global `~/.claude/` settings.

### Configure PBI Pipeline coverage tooling

The Developer agent runs the `pbi-pipeline` skill per assigned PBI,
which measures C0/C1 test coverage with real tooling per Round. Copy
the example config and adapt to your project's stack:

```bash
cp .scrum-config.example.json .scrum/config.json
$EDITOR .scrum/config.json   # set test_runner and coverage_tool
```

For partial-C1 languages (Go, Rust, Bash), set `c1_threshold` in
`.scrum/config.json`. Ad-hoc relaxation is forbidden — the threshold
must be declared in config.

See `docs/MIGRATION-pbi-pipeline.md` if you are upgrading from the
legacy single-session design + implementation flow.

If tmux is available, `scrum-start.sh` creates a split layout:
- **Main pane**: `claude --agent scrum-master` (interactive session in
  **Delegate mode** — the Scrum Master focuses exclusively on coordination
  and cannot write code directly)
- **Side pane**: `python dashboard/app.py` (Textual TUI dashboard)

Without tmux, the compact status line dashboard (3 lines) is used instead.

---

## For Contributors / Developers

Guide for developers contributing to the claude-scrum-team project itself.

### Prerequisites

- Everything from the End User section above, plus:
- **Bash 3.2+** (default on macOS/Linux)
- **jq** for JSON processing (`brew install jq`)

### Development-only Dependencies

- **bats-core** for running tests (`brew install bats-core`)
- **yq** for YAML validation in tests (`brew install yq`)
- **ShellCheck** for linting Bash scripts (`brew install shellcheck`)

### Setup

```bash
# Clone the repository
git clone git@github.com:sohei56/claude-scrum-team.git
cd claude-scrum-team

# Run the contributor setup script (installs dev deps + user setup)
sh scripts/setup-dev.sh

# Or install dependencies manually:
brew install bats-core jq yq shellcheck
git submodule update --init --recursive

# Verify development dependencies
command -v bats && echo "bats-core: OK"
command -v jq && echo "jq: OK"
command -v yq && echo "yq: OK"
command -v shellcheck && echo "shellcheck: OK"
```

## Repository Layout

See [CLAUDE.md § Project Structure](../CLAUDE.md) for the canonical
tree. The repository is organized as: `agents/` (Scrum Master,
Developer, and 6 PBI-pipeline + 3 cross-review sub-agent
definitions), `skills/` (16 Skills covering all Scrum ceremonies
plus the cleanup-audit maintenance skill), `hooks/`, `dashboard/`,
`scripts/`, `tests/`, `docs/`, and the runtime `.scrum/` directory.

## Running Tests and Linting

This document targets end users running the framework. Contributors
should refer to [CONTRIBUTING.md § Running Tests](../CONTRIBUTING.md#running-tests)
for the full bats / shellcheck / ruff invocations and dev-tool
prerequisites.

## Key Concepts

### Agents
- `agents/scrum-master.md` — Team lead in **Delegate mode** (coordination
  only). Preloads all 14 ceremony Skills.
- `agents/developer.md` — Teammate template, spawned per Sprint.
- `agents/code-reviewer.md` — Independent code review (spawned by Scrum Master during cross-review).
- `agents/security-reviewer.md` — Security vulnerability scanning (spawned by Scrum Master during cross-review).
- `agents/codex-code-reviewer.md` — Cross-model review via OpenAI Codex CLI (optional, spawned by Scrum Master).
- `agents/pbi-{designer,implementer,ut-author}.md` — PBI Pipeline workers (spawned per Round by Developer).
- `agents/codex-{design,impl,ut}-reviewer.md` — PBI Pipeline critical reviewers (cross-model via Codex CLI).

### Skills
Markdown files in `.claude/skills/<name>/SKILL.md` encapsulating Scrum
ceremonies. Each declares `## Inputs` and `## Outputs` for explicit
data dependencies. Invoked explicitly (`disable-model-invocation: true`).

### Hooks
Enforce Sprint workflow rules via shell scripts:
`status-gate.sh` (tool gating), `session-context.sh` (status injection),
`completion-gate.sh` (exit criteria), `quality-gate.sh` (DoD).

### State Files
Runtime state in `.scrum/` (JSON, one file per concern).
See `data-model.md` for schemas.

### Dashboard
- **Textual TUI** (`dashboard/app.py`): 4-panel real-time view in tmux.
- **Status line** (`scripts/statusline.sh`): compact 3-line fallback.
- **Hooks** feed events to `.scrum/dashboard.json` and `communications.json`.

### Design Documents
Governed by `docs/design/catalog.md` — no design document may be created
unless its spec type is listed and enabled in the catalog. Files live at
`docs/design/specs/{category}/{id}-{slug}.md`. Each includes `revision_history`
in YAML frontmatter with `pbis` field.

## Development Workflow

1. Read the requirements: `docs/requirements.md`
2. Read the data model: `docs/data-model.md`
3. Read the contracts: `docs/contracts/`
4. Make changes
5. Run `shellcheck` on modified shell scripts
6. Run `bats tests/unit/ tests/lint/` to verify
7. Commit per the task-based commit strategy (Constitution IV)

## Testing an End-to-End Flow

To test the full Scrum workflow manually:

```bash
# Create a temporary test project
mkdir /tmp/test-project && cd /tmp/test-project
git init

# Ensure TUI dependencies are installed (use venv recommended)
python3 -m venv .venv && source .venv/bin/activate
pip install textual watchdog

# Run the setup and launch
sh /path/to/claude-scrum-team/scripts/setup-user.sh
sh /path/to/claude-scrum-team/scrum-start.sh

# Interact with the Scrum team, then verify:
# - .scrum/ directory exists with state files
# - .claude/agents/ contains scrum-master.md and developer.md
# - .claude/skills/ contains all 14 ceremony skills
# - Status line displays at bottom of terminal
# - Textual dashboard appears in tmux side pane (if tmux available)
# - Hooks are configured in .claude/settings.json
# - .scrum/communications.json is populated as agents communicate
# - .scrum/dashboard.json is populated as file changes occur
```

## Useful References

- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Claude Code Sub-agents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code Skills](https://code.claude.com/docs/en/skills)
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code Status Line](https://code.claude.com/docs/en/statusline)
- [Claude Code Headless Mode](https://code.claude.com/docs/en/headless)
- [awesome-claude-code-subagents catalog](https://github.com/VoltAgent/awesome-claude-code-subagents/tree/main)
- [bats-core documentation](https://bats-core.readthedocs.io/)
