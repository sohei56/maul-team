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

See `docs/MIGRATION-pbi-pipeline.md` for a conceptual map between
the legacy single-session design + implementation flow and today's
pbi-pipeline conductor + sub-agents (the legacy skills are no
longer shipped).

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

For deeper detail, follow these pointers:

- **Agents and sub-agents**: top-level Scrum Master + Developer plus 9
  specialist sub-agents — see [docs/contracts/sub-agents.md](contracts/sub-agents.md).
- **Skills**: Markdown + YAML frontmatter under `.claude/skills/<name>/SKILL.md`,
  each with `## Inputs` / `## Outputs`. Invocation, side effects, and
  state writes are documented per skill.
- **Hooks** (`status-gate`, `session-context`, `completion-gate`,
  `quality-gate`, `pre-tool-use-*`): enforce Sprint workflow at the
  Claude Code tool layer — see [docs/architecture.md](architecture.md) R7.
- **State files** in `.scrum/` (one JSON file per concern): schemas in
  [docs/data-model.md](data-model.md); writes go through
  `.scrum/scripts/*.sh` wrappers.
- **Dashboard**: Textual TUI (`dashboard/app.py`) with a 3-line
  statusline fallback (`scripts/statusline.sh`).
- **Design documents**: governed by `docs/design/catalog.md`; files
  live at `docs/design/specs/{category}/{id}-{slug}.md`.

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
# - .claude/skills/ contains all installed Scrum ceremony skills
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
