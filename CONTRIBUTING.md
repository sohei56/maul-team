# Contributing to claude-scrum-team

## Development Setup

```bash
# Clone the repository
git clone https://github.com/sohei56/claude-scrum-team.git
cd claude-scrum-team

# Run the contributor setup script (installs dev deps + user setup)
sh scripts/setup-dev.sh

# Or install dependencies manually:
brew install bats-core jq yq shellcheck
pip install ruff
git submodule update --init --recursive
```

### Prerequisites

- Everything from the [README](README.md) prerequisites, plus:
- **Bash 3.2+** (default on macOS/Linux)
- **bats-core** for running tests
- **jq** for JSON processing
- **yq** for YAML validation
- **ShellCheck** for Bash linting

## Running Tests

```bash
# Run all fast tests (unit + lint)
bats tests/unit/ tests/lint/

# Run unit tests only
bats tests/unit/

# Run agent/skill definition linting
bats tests/lint/

# Run integration tests
bats tests/integration/script-compose.bats
```

## Linting

```bash
# Lint all shell scripts
shellcheck scrum-start.sh scripts/*.sh scripts/lib/*.sh hooks/*.sh hooks/lib/*.sh

# Lint Python code
ruff check dashboard/
ruff format --check dashboard/

# Check agent definition YAML frontmatter
bats tests/lint/agent-frontmatter.bats

# Check skill definition YAML frontmatter
bats tests/lint/skill-frontmatter.bats
```

## Code Style

- **Shell scripts**: Follow ShellCheck recommendations. Target Bash 3.2+
  (macOS default). See `.shellcheckrc` for project defaults.
- **Python**: Follow ruff configuration in `pyproject.toml`. Target
  Python 3.9+.
- **Whitespace**: Follow `.editorconfig` — 2 spaces for shell/JSON/YAML,
  4 spaces for Python.
- **Agent/Skill definitions**: Markdown with YAML frontmatter. All Skills
  must have `## Inputs` and `## Outputs` sections.

## Commit Conventions

Follow the task-based commit strategy (Constitution IV):

- One commit per logical task or change
- Use conventional commit prefixes: `feat:`, `fix:`, `docs:`, `test:`,
  `refactor:`, `chore:`
- Keep commits atomic and focused
- Write clear commit messages explaining **why**, not just **what**

## Project Structure

See [CLAUDE.md § Project Structure](CLAUDE.md) for the canonical
tree. Top-level layout: `scrum-start.sh` (entry point), `agents/`,
`skills/`, `hooks/`, `dashboard/`, `scripts/`, `tests/`,
`docs/design/`, `docs/`.

## Key Files

- `agents/scrum-master.md`, `agents/developer.md` — top-level agents
- Sub-agents (cross-review + PBI pipeline) — see [docs/contracts/sub-agents.md](docs/contracts/sub-agents.md)
- `docs/design/catalog.md` — Design document type reference (read-only in working dirs)
- `docs/design/catalog-config.json` — Editable list of enabled spec IDs
- `docs/` — Project documentation (requirements, architecture, data model, contracts, quickstart)

## Pull Request Process

1. Create a feature branch from `main`
2. Make changes following the code style guidelines
3. Run tests: `bats tests/unit/ tests/lint/`
4. Run linters: `shellcheck`, `ruff`
5. Commit with clear messages
6. Open a PR with a description of changes
