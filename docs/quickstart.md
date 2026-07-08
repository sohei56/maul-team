# Quickstart: Maul Team Development


## For End Users

### Prerequisites

- **Claude Code CLI** installed and on PATH
- **Python 3.9+** installed and on PATH
- **TUI dependencies**: `pip install textual watchdog`
- **tmux** (recommended) for side-by-side dashboard layout

### Getting Started

```bash
# 1. Clone the repository (once)
git clone git@github.com:sohei56/maul-team.git ~/maul-team

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

# 4. Launch the Scrum team (opens tmux with Claude Code + dashboard).
#    This invokes setup-user.sh internally — no separate setup step
#    is required.
sh ~/maul-team/scrum-start.sh

# (Optional) Run setup without launching the team, e.g. to inspect
# what the framework copies into .claude/ before going live:
#   sh ~/maul-team/scripts/setup-user.sh
```

The setup script copies agent definitions and Skills to your project's
`.claude/` directory, configures the status line dashboard, and sets up
hooks. It NEVER modifies your global `~/.claude/` settings.

### Autonomous mode

When you do not want a human at the keyboard, launch with `--autonomous`:

```bash
sh ~/maul-team/scrum-start.sh \
   --autonomous --brief docs/product/brief.md --max-sprints 3
```

This sets `.scrum/config.json.po_mode == "agent"` so the `product-owner`
teammate takes every PO decision, and starts the outer Ralph-Loop
watchdog (`scripts/autonomous/watchdog.sh`) which re-launches headless
Claude sessions, enforces safety valves (iterations / wall clock /
Sprints / consecutive-failure / per-phase Stop-block budget),
backs off on rate-limit signals, and writes a morning report to
`.scrum/reports/autonomous-run-<run_id>.md`. Full operator guide:
[docs/autonomous-mode.md](autonomous-mode.md).

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

Guide for developers contributing to the maul-team project itself.

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
git clone git@github.com:sohei56/maul-team.git
cd maul-team

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
annotated tree.

## Key Concepts

For deeper detail, follow these pointers:

- **Agents and sub-agents**: top-level Scrum Master + Developer +
  Product Owner + Requirements Analyst (Requirement Definition
  ceremony) plus 11 specialist sub-agents (6 PBI pipeline + 5
  cross-review) — see [docs/contracts/sub-agents.md](contracts/sub-agents.md).
- **Skills**: Markdown + YAML frontmatter under `.claude/skills/<name>/SKILL.md`,
  each with `## Inputs` / `## Outputs`. Invocation, side effects, and
  state writes are documented per skill.
- **Hooks** (`status-gate`, `session-context`, `stop-dispatch`
  → `dashboard-event` + `completion-gate`, `quality-gate`,
  `pre-tool-use-*`): enforce Sprint workflow at the Claude Code
  tool layer — see [docs/architecture.md](architecture.md) R7. The
  Stop event is registered once via `stop-dispatch.sh`, which
  forwards to `dashboard-event.sh` (best-effort) and then
  `completion-gate.sh` (gate verdict).
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
7. Commit per the conventions in [CONTRIBUTING.md § Commit Conventions](../CONTRIBUTING.md#commit-conventions)

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
sh /path/to/maul-team/scripts/setup-user.sh
sh /path/to/maul-team/scrum-start.sh

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
