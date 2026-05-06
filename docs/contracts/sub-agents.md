# Sub-Agent Catalog

Canonical reference for project-managed specialist sub-agents. Full
definitions live in `agents/`; this file lists name, role, spawning
parent, and tool sandbox. Distributed to `.claude/agents/` by
`setup-user.sh`.

## Sprint-end Cross-Review (spawned by Scrum Master)

| Agent | Role | Tools |
|---|---|---|
| `codex-code-reviewer` | Cross-model code review via OpenAI Codex CLI (primary) | Read, Grep, Glob, Bash |
| `code-reviewer` | Claude-based code quality + design compliance (fallback when Codex CLI unavailable) | Read, Grep, Glob, Bash (read-only) |
| `security-reviewer` | OWASP Top 10 / vulnerability scan (always parallel) | Read, Grep, Glob, Bash (read-only) |

Spawned by the `cross-review` skill. See FR-009 (requirements.md).
When the `codex` CLI is unavailable, `cross-review` logs a warning and
falls back to `code-reviewer` for the code-quality pass.

## PBI Pipeline (spawned by Developer per Round)

| Agent | Role | Tools |
|---|---|---|
| `pbi-designer` | Per-PBI design spec author | Read, Write, Edit, Grep, Glob, Bash |
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
