# Sub-Agent Catalog

Canonical reference for project-managed specialist sub-agents. Full
definitions live in `agents/`; this file lists name, role, spawning
parent, and tool sandbox. Distributed to `.claude/agents/` by
`setup-user.sh`.

## Sprint-end Cross-Review (spawned by Scrum Master)

5 aspect-specialized reviewers spawned in parallel over the whole
Sprint (no per-PBI fan-out). Findings tag PBIs via `paths_touched`
reverse-lookup. Aspect 1/2/3 FAIL → revert PBI to `in_progress_impl`;
aspect 4/5 FAIL → append follow-up PBI to backlog.

| # | Aspect | Agent | Role | Tools |
|---|---|---|---|---|
| 1 | Requirement conformance | `requirement-conformance-reviewer` | Sprint-wide requirement coverage + scope drift vs. design specs | Read, Grep, Glob, Bash (read-only) |
| 2 | Cross-PBI functional quality | `functional-quality-reviewer` | PBI-to-PBI seams: boundary values, error propagation, state transitions, data integrity | Read, Grep, Glob, Bash (read-only) |
| 3 | Security | `security-reviewer` | OWASP Top 10 / vulnerability scan | Read, Grep, Glob, Bash (read-only) |
| 4 | Maintainability | `maintainability-reviewer` | Abstraction, duplication, cohesion, god-class/function, dead code (static-analysis-grounded) | Read, Grep, Glob, Bash (read-only) |
| 5 | Docs consistency | `docs-consistency-reviewer` | `docs/**` vs. implementation drift, stale wording, missing follow-up | Read, Grep, Glob, Bash (read-only) |

Spawned by the `cross-review` skill. See FR-009 (requirements.md).
The skill runs a static analysis pass (Python `ruff` / Shell
`shellcheck`) before spawning the maintainability reviewer; results
land at `.scrum/reviews/static-analysis-r{n}.json`.

## PBI Pipeline (spawned by Developer per Round)

| Agent | Role | Tools |
|---|---|---|
| `pbi-designer` | Per-PBI design spec author + library selection (S-070 verified specs) | Read, Write, Edit, Grep, Glob, Bash, WebSearch, WebFetch |
| `pbi-implementer` | Source code (no test writes) | Read, Write, Edit, Grep, Glob, Bash |
| `pbi-ut-author` | Black-box UT (no impl reads) | Read, Write, Edit, Grep, Glob, Bash |
| `codex-design-reviewer` | Cross-model design critique | Read, Grep, Glob, Bash |
| `codex-impl-reviewer` | Cross-model impl review (no test visibility) | Read, Grep, Glob, Bash |
| `codex-ut-reviewer` | Cross-model UT review (no impl visibility) | Read, Grep, Glob, Bash |

Spawned per Round by the `pbi-pipeline` skill. Path-level constraints
on `pbi-implementer` and `pbi-ut-author` are enforced by
`hooks/pre-tool-use-path-guard.sh`. See FR-019 (requirements.md) and
R10 (architecture.md).

## Installation

Distributed by `setup-user.sh` from this repo's `agents/` to the
target project's `.claude/agents/`. The `install-subagents` skill
verifies all PBI Pipeline sub-agents are present at PBI start;
missing required sub-agent → BLOCK.
