<p align="center">
  <img alt="claude-scrum-team" src="images/claude-scrum-team.png" width="700">
</p>

<h1 align="center">claude-scrum-team</h1>

<p align="center">
  <strong>AI-Powered Scrum Team for Claude Code — a full Scrum workflow driven by multi-agent coordination via Agent Teams</strong>
</p>

<p align="center">
  <a href="https://github.com/sohei56/claude-scrum-team/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sohei56/claude-scrum-team?style=flat-square&color=blue" alt="License"></a>
  <img src="https://img.shields.io/badge/python-3.9%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+">
  <img src="https://img.shields.io/badge/Claude_Code-Agent_Teams-D97706?style=flat-square&logo=anthropic&logoColor=white" alt="Claude Code Agent Teams">
  <img src="https://img.shields.io/badge/TUI-Textual-7C3AED?style=flat-square" alt="Textual TUI">
</p>

<p align="center">
  <strong>English</strong> | <a href="README_ja.md">日本語</a>
</p>

<p align="center">
  <a href="#why">Why?</a> &bull;
  <a href="#demo">Demo</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#development">Development</a>
</p>

---

Run `scrum-start.sh` in any project directory and a full AI Scrum team takes over — a **Scrum Master** coordinates **Developer** agents through Sprint cycles while you act as the **Product Owner**, approving goals and reviewing the working product.

## Why?

Vibe coding's speed is attractive, but order erodes as a project runs longer. Spec-Driven Development (SDD) keeps order well, but demands defining a lot upfront. Most real projects live in between — not everything is decided on day one, yet you still need to maintain order as you go.

**claude-scrum-team** brings Scrum's inspect-and-adapt loop to Claude Code, giving you structured iteration without requiring a complete specification on day one. You stay in the Product Owner seat — describing what you want, approving Sprint Goals, and reviewing working software each Sprint — while a team of AI agents handles the rest.

## Demo

<p align="center">
  <img alt="scrum-start.sh demo" src="images/demo.gif" width="800">
</p>

One command sets up agents, skills, and hooks — then launches Claude Code with a Scrum Master agent alongside a real-time TUI dashboard in tmux.

### What a session looks like

1. **You describe your project** — the Scrum Master spawns a Developer to elicit requirements and write `requirements.md`
2. **Backlog Refinement** — the SM creates and refines PBIs from your requirements
3. **Sprint Planning** — the SM proposes a Sprint Goal; you approve or adjust
4. **PBI Pipeline (parallel, per-PBI)** — each Developer acts as a conductor running the `pbi-pipeline` skill on its assigned PBI in its own git worktree (`.scrum/worktrees/<pbi-id>/`, branch `pbi/<pbi-id>`): rounds of design → implementation + black-box UT → cross-model (Codex) review, with deterministic termination gates and real C0/C1 coverage measurement. On PBI completion the SM merges that PBI immediately (`--no-ff` + per-merge regression gate, 3-strike escalation).
5. **Cross-Review** — once all PBIs are merged, the SM spawns 5 aspect-specialized reviewer sub-agents (requirement-conformance, functional-quality, security, maintainability, docs-consistency) in parallel over the whole Sprint Increment
6. **Sprint Review** — the SM launches the app and demos every completed PBI; you confirm each works
7. **Retrospective** — the team reflects and records improvements for the next Sprint
8. **Repeat** until the Product Goal is achieved, then an **Integration Sprint** runs smoke tests, design-completeness verification, and a final user-story-driven UAT

## Features

- **17 Skills** (16 Scrum ceremonies + 1 PO acceptance) covering the full Scrum lifecycle: requirements elicitation, backlog refinement, sprint planning, PBI pipeline (design + impl + UT + per-PBI review), per-PBI merge, cross-review, sprint review, retrospective, and integration testing
- **Multi-agent coordination** — Scrum Master (Delegate mode) orchestrates up to 6 parallel Developer agents per Sprint (1 Developer per PBI, capped at 6)
- **Autonomous PO mode** (`--autonomous`) — runs the team end-to-end with an AI Product Owner (`po_mode=agent`). An outer Ralph-Loop watchdog (`scripts/autonomous/watchdog.sh`) re-launches headless Claude sessions, enforces safety valves (iterations / wall clock / Sprints / budget) and writes a morning report to `.scrum/reports/`. See [docs/autonomous-mode.md](docs/autonomous-mode.md).
- **Real-time TUI dashboard** — Textual-based three-panel display (Sprint Overview, PBI Progress Board, unified Work Log of agent messages + work events) with watchdog filesystem monitoring
- **Design document governance** — immutable catalog (`catalog.md`) with editable enablement config (`catalog-config.json`) enforced by status-gate hooks, controlling the documents AI agents are allowed to create
- **Quality enforcement hooks** — status gates, path guards, branch-ops guard, completion-flow enforcement (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`), quality gates (Definition of Done), session context restoration, plus an external stall watchdog (`scripts/stall-watchdog.sh`) in human mode — turning the behaviors you want agents to follow into mechanisms
- **State persistence** — all state in `.scrum/` JSON files for full session resume capability
- **Automated testing** — Integration Sprints run smoke tests (unit + e2e), design-completeness verification, optional browser E2E via Playwright MCP, and a story-driven UAT
- **Retrospective-driven improvement** — improvements from past Sprints are applied automatically

### AI-Specific Adaptations

This is not a carbon copy of human Scrum — it adapts the framework to how AI agents actually work.

**Extensions leveraging AI strengths:**

- **Dynamic team sizing** — the number of Developer agents is optimized per Sprint based on PBI count and complexity
- **Independent cross-review** — 5 aspect-specialized reviewer sub-agents (`requirement-conformance-reviewer`, `functional-quality-reviewer`, `security-reviewer`, `maintainability-reviewer`, `docs-consistency-reviewer`) run in parallel over the whole Sprint Increment, plus per-PBI Codex-CLI cross-model review

**Constraints addressing AI weaknesses:**

- **Mandatory Requirements Sprint** — the first Sprint is dedicated solely to requirements elicitation, preventing the team from charging ahead without a map
- **No work without a PBI** — all development must be tied to a backlog item, stopping the Scrum Master from drifting into ad-hoc fixes mid-conversation
- **Controlled document creation** — only document types listed in the design catalog may be created, curbing the AI tendency to produce sprawling, unstructured documentation
- **PO-driven Sprint scope** — Sprint boundaries are set by meaningful review checkpoints rather than velocity estimates, since AI agents have no stable velocity baseline

### Sprint Lifecycle

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Requirements Sprint (Sprint 0)                             │
 │  Requirements Elicitation ──▶ Initial Product Backlog       │
 └──────────────────────────────┬──────────────────────────────┘
                                ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  Sprint N                                                   │
 │                                                             │
 │  1. Backlog Refine    PBIs: draft ──▶ refined               │
 │          ▼                                                  │
 │  2. Planning          PO approves Sprint Goal               │
 │          ▼                                                  │
 │  3. Scaffold Specs    Create design doc stubs from catalog  │
 │          ▼                                                  │
 │  4. Spawn Teammates   Launch Developer agents + worktrees   │
 │          ▼                                                  │
 │  5. PBI Pipeline      Per Developer / per PBI, in parallel: │
 │                         design → impl + black-box UT →      │
 │                         cross-model (Codex) review, with    │
 │                         deterministic termination gates     │
 │                         and real C0/C1 coverage             │
 │          ▼                                                  │
 │  6. Per-PBI Merge     SM merges each ready PBI immediately  │
 │                         (--no-ff + regression gate;         │
 │                         3-strike escalation)                │
 │          ▼                                                  │
 │  7. Cross-Review      SM spawns 5 aspect reviewer agents    │
 │          ▼                                                  │
 │  8. Sprint Review     Demo to PO, accept/reject PBIs        │
 │          ▼                                                  │
 │  9. Retrospective     Record improvements for next Sprint   │
 └──────────┬──────────────────────────┬───────────────────────┘
            │                          │
            ▼                          ▼
     Next Sprint N+1   ┌───────────────────────────────────────┐
                       │  Integration Sprint                   │
                       │  Smoke ──▶ Design-Completeness ──▶    │
                       │  Story-driven UAT ──▶ Release         │
                       └───────────────────────────────────────┘
```

## Quick Start

```bash
# Clone the repository
git clone git@github.com:sohei56/claude-scrum-team.git

# In your project directory:
cd /path/to/your/project

# Launch the Scrum team (auto-installs Python dependencies if needed)
sh /path/to/claude-scrum-team/scrum-start.sh

# Or: launch in autonomous PO mode (no human at the keyboard)
sh /path/to/claude-scrum-team/scrum-start.sh \
   --autonomous --brief docs/product/brief.md --max-sprints 3
```

The script validates prerequisites (auto-installing `textual` and `watchdog` if missing), copies agent definitions, Skills, hooks, shared rules, and the design catalog to your project's `.claude/` directory, and launches a tmux session with Claude Code (Scrum Master) and the TUI dashboard.

For detailed setup instructions, see [quickstart.md](docs/quickstart.md). For autonomous-mode operation (safety valves, budgets, morning report), see [docs/autonomous-mode.md](docs/autonomous-mode.md).

### Prerequisites

- **Claude Code CLI** installed and on PATH — **2.1.172 or later recommended** (see [Claude Code version](#claude-code-version) below)
- **Python 3.9+** with `textual` and `watchdog`
- **tmux** (recommended) for side-by-side dashboard layout

#### Claude Code version

`scrum-start.sh` emits a warning when Claude Code is older than **2.1.172**. The PBI pipeline (the `pbi-pipeline` skill) relies on the Developer sub-agent spawning further specialist sub-agents — `pbi-designer`, `pbi-implementer`, `pbi-ut-author`, and the `codex-{design,impl,ut}-reviewer` trio. **Sub-agents spawning further sub-agents was unlocked upstream in Claude Code 2.1.172** ([changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)). On older versions the Developer's tool surface lacks `Agent` / `Task` and the pipeline halts at the design stage.

Upgrade paths:

- **Homebrew** — the stock `claude-code` cask is frozen at 2.1.153; switch to the rolling-release cask:
  ```bash
  brew uninstall --cask claude-code
  brew install --cask claude-code@latest
  ```
- **Native installer** — `curl -fsSL https://claude.ai/install.sh | bash`

Sessions, memory, and settings under `~/.claude/` are preserved across either upgrade.

### Your role as Product Owner

| You do | The AI team does |
|--------|-----------------|
| Describe what you want to build | Elicit and write detailed requirements |
| Approve Sprint Goals | Plan Sprints and assign PBIs |
| Review demos in the running app | Design, implement, and run cross-review on the Increment |
| Report defects during UAT | Fix defects and re-test automatically |
| Make release decisions | Run automated test suites |

> The PO seat can also be delegated to the `product-owner` agent via `po_mode=agent` (autonomous mode); decisions are persisted to `.scrum/po/decisions.json`. See [docs/autonomous-mode.md](docs/autonomous-mode.md).

## Architecture

- **`scrum-start.sh`** — Entry point: validates prereqs, runs `scripts/setup-user.sh` internally to copy agents/skills/hooks/rules into the target project, then launches tmux. Supports `--autonomous --brief <file> --max-sprints <N>`.
- **`agents/`** — 3 top-level agents (Scrum Master in Delegate mode, Developer, Product Owner) plus 11 specialist sub-agents (5 cross-review reviewers + 6 PBI Pipeline sub-agents, including the Codex-CLI cross-model reviewers). Catalog: [docs/contracts/sub-agents.md](docs/contracts/sub-agents.md)
- **`skills/`** — 17 Skills (16 Scrum ceremonies + 1 PO acceptance) with mandatory Inputs/Outputs
- **`hooks/`** — Status gates, path guards, branch-ops guard, single Stop entry (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`), quality gates, session context. Plus `scripts/stall-watchdog.sh` (external teammate-stall monitor in human mode).
- **`rules/`** — Cross-cutting Scrum context (team map, SSOT locations, communication protocol) auto-loaded by every agent via `.claude/rules/`
- **`dashboard/app.py`** — Textual TUI with real-time panels (Sprint Overview, PBI Board, Work Log)
- **`scripts/`** — Status line, user setup, contributor setup, autonomous-mode watchdog (`scripts/autonomous/`)
- **`.scrum/`** — Runtime state (JSON, gitignored)
- **`docs/design/`** — Design documents governed by `catalog.md` (read-only) + `catalog-config.json` (enabled list)

Per-PBI cross-model review is performed by the `codex-{design,impl,ut}-reviewer` sub-agents, which shell out to the OpenAI Codex CLI (`codex`). No bundled MCP-server bridge is required.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and workflow.

## License

[MIT](LICENSE)
