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

Vibe coding is fast but chaotic. Spec-Driven Development (SDD) is disciplined but demands everything upfront. Most real projects live in between — requirements are fuzzy and need to be shaped as you go.

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
4. **Design + Implementation + Cross-Review** — Developers design and implement their PBIs in parallel, then review each other's work (no self-review)
5. **Sprint Review** — the SM launches the app and demos every completed PBI; you confirm each works
6. **Retrospective** — the team reflects and records improvements for the next Sprint
7. **Repeat** until the Product Goal is achieved, then an **Integration Sprint** runs automated tests and a final UAT

## Features

- **14 ceremony skills** covering the full Scrum lifecycle: requirements elicitation, backlog refinement, sprint planning, design, implementation, cross-review, sprint review, retrospective, and integration testing
- **Multi-agent coordination** — Scrum Master (Delegate mode) orchestrates up to 6 parallel Developer agents per Sprint
- **Real-time TUI dashboard** — Textual-based four-panel display (Sprint Overview, PBI Progress Board, Communication Log, Work Log) with watchdog filesystem monitoring
- **Design document governance** — immutable catalog (`catalog.md`) with editable enablement config (`catalog-config.json`), enforced by phase-gate hooks
- **Quality enforcement hooks** — phase gates (source code restrictions), completion gates (exit criteria), quality gates (Definition of Done), dashboard events, and session context restoration
- **State persistence** — all state in `.scrum/` JSON files for full session resume capability
- **Automated testing** — Integration Sprints run smoke tests, unit tests, and E2E via Playwright
- **Retrospective-driven improvement** — improvements from past Sprints are applied automatically

### AI-Specific Adaptations

This is not a carbon copy of human Scrum — it adapts the framework to how AI agents actually work.

**Extensions leveraging AI strengths:**

- **Dynamic team sizing** — the number of Developer agents is optimized per Sprint based on PBI count and complexity
- **Independent cross-review** — the Scrum Master spawns project-managed reviewer sub-agents (`codex-code-reviewer` primary, `security-reviewer`, with `code-reviewer` as Codex-CLI-unavailable fallback) for unbiased, design-driven code review that checks implementation against requirements and design docs

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
 │  4. Spawn Teammates   Launch Developer agents for PBIs      │
 │          ▼                                                  │
 │  5. Design            Write design specs (parallel)         │
 │          ▼                                                  │
 │  6. Implementation    Build features with TDD (parallel)    │
 │          ▼                                                  │
 │  7. Cross-Review      Devs review each other's work         │
 │          ▼                                                  │
 │  8. Sprint Review     Demo to PO, accept/reject PBIs        │
 │          ▼                                                  │
 │  9. Retrospective     Record improvements for next Sprint   │
 └──────────┬──────────────────────────┬───────────────────────┘
            │                          │
            ▼                          ▼
     Next Sprint N+1   ┌───────────────────────────────────────┐
                       │  Integration Sprint                   │
                       │  Smoke Tests ──▶ UAT ──▶ Release      │
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
```

The script validates prerequisites (auto-installing `textual` and `watchdog` if missing), copies agent definitions, Skills, hooks, and the design catalog to your project's `.claude/` directory, and launches a tmux session with Claude Code (Scrum Master) and the TUI dashboard.

For detailed setup instructions, see [quickstart.md](docs/quickstart.md).

### Prerequisites

- **Claude Code CLI** installed and on PATH
- **Python 3.9+** with `textual` and `watchdog`
- **tmux** (recommended) for side-by-side dashboard layout

### Your role as Product Owner

| You do | The AI team does |
|--------|-----------------|
| Describe what you want to build | Elicit and write detailed requirements |
| Approve Sprint Goals | Plan Sprints and assign PBIs |
| Review demos in the running app | Design, implement, and cross-review code |
| Report defects during UAT | Fix defects and re-test automatically |
| Make release decisions | Run automated test suites |

## Architecture

- **`scrum-start.sh`** — Entry point: validates prereqs, copies agents/skills, launches tmux
- **`agents/`** — Scrum Master (Delegate mode) and Developer agent definitions, plus project-managed specialist sub-agents (cross-review + PBI Pipeline). Catalog: [docs/contracts/sub-agents.md](docs/contracts/sub-agents.md)
- **`skills/`** — 14 ceremony Skills with mandatory Inputs/Outputs
- **`hooks/`** — Phase gates, completion gates, quality gates, dashboard events, session context
- **`dashboard/app.py`** — Textual TUI with real-time panels
- **`scripts/`** — Status line, user setup, contributor setup
- **`.scrum/`** — Runtime state (JSON, gitignored)
- **`docs/design/`** — Design documents governed by `catalog.md` (read-only) + `catalog-config.json` (enabled list)
- **`.mcp-servers/`** — MCP server implementations (OpenAI/Codex bridge for cross-model review)

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and workflow.

## License

[MIT](LICENSE)
