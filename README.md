<p align="center">
  <img alt="claude-scrum-team" src="images/claude-scrum-team.png" width="700">
</p>

<h1 align="center">claude-scrum-team</h1>

<p align="center">
  <strong>A native Mac app — or one shell command — hands your project to a full AI Scrum team, powered by Claude Code Agent Teams</strong>
</p>

<p align="center">
  <a href="https://github.com/sohei56/claude-scrum-team/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sohei56/claude-scrum-team?style=flat-square&color=blue" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Claude_Code-Agent_Teams-D97706?style=flat-square&logo=anthropic&logoColor=white" alt="Claude Code Agent Teams">
  <img src="https://img.shields.io/badge/python-3.9%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+">
</p>

<p align="center">
  <strong>English</strong> | <a href="README_ja.md">日本語</a>
</p>

<p align="center">
  <a href="#why">Why?</a> &bull;
  <a href="#demo">Demo</a> &bull;
  <a href="#get-started">Get Started</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#command-line-advanced">Command line</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#development">Development</a>
</p>

---

Open a project in **ScrumTeam.app** (or run `scrum-start.sh` from a terminal) and a full AI Scrum team takes over — a **Scrum Master** coordinates **Developer** agents through Sprint cycles while you act as the **Product Owner**, approving goals and reviewing the working product.

## Why?

Vibe coding's speed is attractive, but order erodes as a project runs longer. Spec-Driven Development (SDD) keeps order well, but demands defining a lot upfront. Most real projects live in between — not everything is decided on day one, yet you still need to maintain order as you go.

**claude-scrum-team** brings Scrum's inspect-and-adapt loop to Claude Code, giving you structured iteration without requiring a complete specification on day one. You stay in the Product Owner seat — describing what you want, approving Sprint Goals, and reviewing working software each Sprint — while a team of AI agents handles the rest.

## Demo

<p align="center">
  <img alt="ScrumTeam.app — the three-pane workspace" src="images/macapp-hero.png" width="900">
</p>

https://github.com/user-attachments/assets/cb40730c-4b58-42a5-9310-e73864860c1e

**ScrumTeam.app** puts the whole team in one window: pick or create a project, then watch the Scrum Master run the Sprint in an embedded terminal while a native dashboard tracks the PBI board and a tabbed editor lets you read the code as it lands.

## Get Started

The easiest way in is the **Mac App** — a native macOS window that wraps the whole framework (project picker, embedded Scrum Master terminal, tabbed code editor, native dashboard). Prefer a terminal, or on Linux? Jump to [Command line](#command-line-advanced).

### Install (early access — build from source)

> **Early access.** ScrumTeam.app currently builds locally with Xcode 15+ (one script, ~2 min after the first dependency fetch). A signed, notarized `.dmg` and a Homebrew tap will ship with the first notarized release, which is pending Apple Developer enrollment. Until then, build it locally:

```bash
git clone git@github.com:sohei56/claude-scrum-team.git
cd claude-scrum-team
sh macapp/scripts/make-app.sh          # build build/ScrumTeam.app (add `release` for a universal2 build)
open macapp/build/ScrumTeam.app
```

**Requirements:**

- **macOS 13+** and **Xcode 15+** (Swift 5.9+) for the source build, plus network access on the first build (to fetch [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))
- **Claude Code CLI** on PATH, **2.1.172 or later** — the app runs `scrum-start.sh`, whose PBI pipeline relies on sub-agents spawning further sub-agents (unlocked in 2.1.172). See [Claude Code version](#claude-code-version)
- **Python 3.9+** — `scrum-start.sh` validates it at launch and installs `textual` + `watchdog` if missing (the Mac App's own dashboard is native SwiftUI, but the launcher still checks these)

### First run

- **Point it at the framework** — the app auto-detects your `claude-scrum-team` checkout; set it in **Settings (⌘,)** if it isn't found.
- **Pick or create a project** — open an existing folder, or **New Project** deploys the framework (agents, skills, hooks, rules) into a fresh one — the same setup `scrum-start.sh` performs.
- **One window, the whole team** — left: a file tree + tabbed editor (syntax highlighting, detachable windows, framework files lock-marked); center: the Scrum Master terminal + a native Work Log of agent activity; right: a native dashboard — sprint overview, PBI board (click any PBI for details), integration test results.
- **Run the Sprint** — talk to the Scrum Master in the terminal: describe your product, answer the requirements interview, approve Sprint Goals, watch PBIs move across the board, and review each demo. You are the Product Owner; the team does the rest.
- **Edit alongside the run** — open the code the team is writing in tabs while the Sprint progresses.
- **Step away** — back in the picker, choose **Keep Running** and the session keeps working in the background (green **Running** lamp), re-attaching with full scrollback when you return. (Sessions end when you quit the app.)

See [macapp/README.md](macapp/README.md) for the full architecture — editor, background sessions, bundled-framework resolution, and distribution status.

### What a Sprint looks like

1. **You describe your project** — the Scrum Master spawns a Requirements Analyst to elicit requirements, research similar products via web search, and write `requirements.md`
2. **Backlog Refinement** — the SM creates and refines PBIs from your requirements
3. **Sprint Planning** — the SM proposes a Sprint Goal; you approve or adjust
4. **PBI Pipeline (parallel, per-PBI)** — each Developer acts as a conductor running the `pbi-pipeline` skill on its assigned PBI in its own git worktree (`.scrum/worktrees/<pbi-id>/`, branch `pbi/<pbi-id>`): rounds of design → implementation + black-box UT → cross-model (Codex) review, with deterministic termination gates and real C0/C1 coverage measurement. On PBI completion the SM merges that PBI immediately (`--no-ff` + per-merge regression gate, 3-strike escalation).
5. **Cross-Review** — once all PBIs are merged, the SM spawns 5 aspect-specialized reviewer sub-agents (requirement-conformance, functional-quality, security, maintainability, docs-consistency) in parallel over the whole Sprint Increment
6. **Sprint Review** — the SM launches the app and demos every completed PBI; you confirm each works
7. **Retrospective** — the team reflects and records improvements for the next Sprint
8. **Repeat** until the Product Goal is achieved, then **Integration Tests** derives boundary-value and branch-coverage test cases from the design specs and runs them (smoke + API/UI automation), followed by **UAT & Release** — a final user-story-driven UAT and the go/no-go release decision

## Your role as Product Owner

| You do | The AI team does |
|--------|-----------------|
| Describe what you want to build | Elicit and write detailed requirements |
| Approve Sprint Goals | Plan Sprints and assign PBIs |
| Review demos in the running app | Design, implement, and run cross-review on the Increment |
| Report defects during UAT | Fix defects and re-test automatically |
| Make release decisions | Run automated test suites |

> The PO seat can also be delegated to the `product-owner` agent via `po_mode=agent` (autonomous mode); decisions are persisted to `.scrum/po/decisions.json`. See [docs/autonomous-mode.md](docs/autonomous-mode.md).

## Features

- **Native Mac app** — ScrumTeam.app runs the whole team in one macOS window (project picker, embedded Scrum Master terminal, tabbed code editor, native dashboard). It wraps the same framework, so Sprints, agents, and `.scrum/` state are identical to the command line. See [Get Started](#get-started).
- **18 Skills** (16 Scrum ceremonies + 1 PO acceptance + 1 brief authoring) covering the full Scrum lifecycle: product-brief co-authoring, requirements elicitation, backlog refinement, sprint planning, PBI pipeline (design + impl + UT + per-PBI review), per-PBI merge, cross-review, sprint review, retrospective, integration testing, and UAT & release
- **Multi-agent coordination** — Scrum Master (Delegate mode) orchestrates up to 6 parallel Developer agents per Sprint (1 Developer per PBI, capped at 6)
- **Autonomous PO mode** (`--autonomous`, command line) — runs the team end-to-end with an AI Product Owner (`po_mode=agent`). An outer Ralph-Loop watchdog (`scripts/autonomous/watchdog.sh`) re-launches headless Claude sessions, enforces safety valves (iterations / wall clock / Sprints / consecutive failures / per-phase Stop-block budget) and writes a morning report to `.scrum/reports/`. See [docs/autonomous-mode.md](docs/autonomous-mode.md).
- **Design document governance** — immutable catalog (`catalog.md`) with editable enablement config (`catalog-config.json`) enforced by status-gate hooks, controlling the documents AI agents are allowed to create
- **Quality enforcement hooks** — status gates, path guards, branch-ops guard, completion-flow enforcement (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`), quality gates (Definition of Done), session context restoration, plus an external stall watchdog (`scripts/stall-watchdog.sh`) in human mode — turning the behaviors you want agents to follow into mechanisms
- **State persistence** — all state in `.scrum/` JSON files for full session resume capability
- **Automated testing** — Integration Tests runs smoke tests (unit + e2e) plus design-driven test cases covering boundary values and flow/pattern branches, automated as committed API + Playwright UI tests; UAT & Release then runs a story-driven UAT (Playwright MCP / Chrome DevTools MCP-assisted) and the release decision
- **Retrospective-driven improvement** — improvements from past Sprints are applied automatically

### AI-Specific Adaptations

This is not a carbon copy of human Scrum — it adapts the framework to how AI agents actually work.

**Extensions leveraging AI strengths:**

- **Dynamic team sizing** — the number of Developer agents is optimized per Sprint based on PBI count and complexity
- **Independent cross-review** — 5 aspect-specialized reviewer sub-agents (`requirement-conformance-reviewer`, `functional-quality-reviewer`, `security-reviewer`, `maintainability-reviewer`, `docs-consistency-reviewer`) run in parallel over the whole Sprint Increment, plus per-PBI Codex-CLI cross-model review

**Constraints addressing AI weaknesses:**

- **Mandatory Requirement Definition** — the first Sprint (Sprint 0) is dedicated solely to requirements elicitation, preventing the team from charging ahead without a map
- **No work without a PBI** — all development must be tied to a backlog item, stopping the Scrum Master from drifting into ad-hoc fixes mid-conversation
- **Controlled document creation** — only document types listed in the design catalog may be created, curbing the AI tendency to produce sprawling, unstructured documentation
- **PO-driven Sprint scope** — Sprint boundaries are set by meaningful review checkpoints rather than velocity estimates, since AI agents have no stable velocity baseline

### Sprint Lifecycle

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Requirement Definition (Sprint 0)                          │
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
                       │  Integration Tests ──▶ UAT & Release  │
                       │  Smoke ──▶ Design-Driven Cases ──▶    │
                       │  Stub/Automate ──▶ UAT ──▶ Release    │
                       └───────────────────────────────────────┘
```

## Command line (advanced)

Prefer a terminal — or running headless, remote, or on Linux? The same framework runs from the shell, and this path is required for **autonomous mode**.

```bash
# Clone the repository
git clone git@github.com:sohei56/claude-scrum-team.git

# In your project directory:
cd /path/to/your/project

# Launch the Scrum team (auto-installs Python dependencies if needed)
sh /path/to/claude-scrum-team/scrum-start.sh

# Or: launch in autonomous PO mode (no human at the keyboard)
sh /path/to/claude-scrum-team/scrum-start.sh --autonomous --brief docs/product/brief.md
```

The script validates prerequisites (auto-installing `textual` and `watchdog` if missing), copies agent definitions, Skills, hooks, shared rules, and the design catalog to your project's `.claude/` directory, and launches a tmux session with Claude Code (Scrum Master) and the TUI dashboard.

<p align="center">
  <img alt="scrum-start.sh demo" src="images/demo.gif" width="800">
</p>

> Already deployed this framework to a project before? Re-run `scrum-start.sh` to refresh `.claude/` — it is a copied snapshot, not a live link, so Skill renames/additions (e.g. the Integration Sprint split into `integration-tests` + `uat-release`) only reach an existing project after a re-run.

For detailed setup instructions, see [quickstart.md](docs/quickstart.md). For autonomous-mode operation (safety valves, Stop-block budgets, morning report), see [docs/autonomous-mode.md](docs/autonomous-mode.md).

### Command-line prerequisites

- **Claude Code CLI** ≥ **2.1.172** and **Python 3.9+** — the shared prerequisites above under [Get Started](#install-early-access--build-from-source)
- **tmux** (recommended) for the side-by-side dashboard layout

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

## Architecture

- **`scrum-start.sh`** — Entry point: validates prereqs, runs `scripts/setup-user.sh` internally to copy agents/skills/hooks/rules into the target project, then launches tmux. Supports `--autonomous --brief <file> --max-sprints <N>`.
- **`macapp/`** — Native macOS shell (SwiftUI + SwiftTerm): project picker, tabbed editor, embedded Scrum Master terminal, and a native dashboard, all driving the same `scrum-start.sh`. See [macapp/README.md](macapp/README.md).
- **`agents/`** — 4 top-level agents (Scrum Master in Delegate mode, Developer, Product Owner, Requirements Analyst) plus 11 specialist sub-agents (5 cross-review reviewers + 6 PBI Pipeline sub-agents, including the Codex-CLI cross-model reviewers). Catalog: [docs/contracts/sub-agents.md](docs/contracts/sub-agents.md)
- **`skills/`** — 18 Skills (16 Scrum ceremonies + 1 PO acceptance + 1 brief authoring) with mandatory Inputs/Outputs
- **`hooks/`** — Status gates, path guards, branch-ops guard, single Stop entry (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`), quality gates, session context. Plus `scripts/stall-watchdog.sh` (external teammate-stall monitor in human mode).
- **`rules/`** — Cross-cutting Scrum context (team map, SSOT locations, communication protocol) auto-loaded by every agent via `.claude/rules/`
- **`dashboard/app.py`** — Textual TUI with real-time panels (Sprint Overview, PBI Board, Work Log) for the command-line path
- **`scripts/`** — Status line, user setup, contributor setup, autonomous-mode watchdog (`scripts/autonomous/`)
- **`.scrum/`** — Runtime state (JSON, gitignored)
- **`docs/design/`** — Design documents governed by `catalog.md` (read-only) + `catalog-config.json` (enabled list)

Per-PBI cross-model review is performed by the `codex-{design,impl,ut}-reviewer` sub-agents, which shell out to the OpenAI Codex CLI (`codex`). No bundled MCP-server bridge is required.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and workflow.

## License

[MIT](LICENSE)
