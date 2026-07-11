# Sub-Agent Catalog

Canonical reference for project-managed specialist sub-agents. Full
definitions live in `agents/`; this file lists name, role, spawning
parent, and tool sandbox. Distributed to `.claude/agents/` by
`setup-user.sh`.

## Sprint-end Codebase Audit (spawned by Scrum Master)

Sprint-end cross-review is now **audit-only**. It runs the whole-repo
`codebase-audit` along four axes — one parallel auditor per axis. The
axes are **not named catalog agents**: each is a **general-purpose
`Agent`-tool spawn** whose prompt is assembled from the common protocol
plus the axis template in `skills/codebase-audit/references/axes.md`.
They are read-only, whole-repo (no per-PBI fan-out, no `paths_touched`
partition), and **non-blocking** — they never revert a PBI. Critical/High
findings become draft PBIs for the **next** Sprint.

| # | Axis | Focus | Only-visible-whole-repo catch |
|---|---|---|---|
| 1 | `spec-conformance` | Implementation vs enabled specs + requirements | Divergences, coded-but-unspecified behavior, spec-vs-spec conflicts |
| 2 | `logic-defect` | I/O orchestration + wiring layer | Feature-disabling defaults, silent failures, wiring-layer edge cases |
| 3 | `redundancy` | Dead code, cross-PBI duplication, stale docs | Unused exports (static-analysis-grounded), cross-PBI duplicate logic, stale docstrings |
| 4 | `product-security` | Product-wide security integrity | Cross-component authz, trust-boundary data flow, whole-repo secret handling, integration-point injection surfaces |

Spawned by the `cross-review` skill via the `codebase-audit` skill.
See FR-009 (requirements.md). Before spawning, `cross-review` runs a
two-pass static analysis that now feeds the **`redundancy` audit axis**
(no Sprint-level maintainability aspect exists any more): Pass A is
intra-file lint on the Sprint diff (Python `ruff` / Shell `shellcheck`);
Pass B is a whole-repo dead-export / reachability scan (built-in
`vulture` for Python, or the per-language commands in
`.scrum/config.json.static_analysis.commands[]` such as `knip` /
`ts-prune` / `staticcheck` / `cargo-udeps`). Both passes aggregate into
`.scrum/reviews/static-analysis-r{n}.json`, which the `redundancy` axis
cites as ground truth.

## PBI Pipeline (spawned by Developer per Round)

| Agent | Role | Tools |
|---|---|---|
| `pbi-designer` | Per-PBI design spec author + library selection (S-070 verified specs) | Read, Write, Edit, Grep, Glob, Bash, WebSearch, WebFetch |
| `pbi-implementer` | Source code (no test writes) | Read, Write, Edit, Grep, Glob (Bash hook-blocked) |
| `pbi-ut-author` | Black-box UT (no impl reads) | Read, Write, Edit, Grep, Glob (Bash hook-blocked) |
| `codex-design-reviewer` | Cross-model design critique | Read, Grep, Glob, Bash, Write (verdict self-persist only) |
| `codex-impl-reviewer` | Cross-model impl review (no test visibility) | Read, Grep, Glob, Bash, Write (verdict self-persist only) |
| `codex-ut-reviewer` | Cross-model UT review (no impl visibility) | Read, Grep, Glob, Bash, Write (verdict self-persist only) |

Spawned per Round by the `pbi-pipeline` skill. Path-level constraints
on `pbi-implementer` and `pbi-ut-author` are enforced by
`hooks/pre-tool-use-path-guard.sh`. The codex reviewers' `Write` is
for the mandatory verdict self-persist (`review-r{n}.md`) only —
`hooks/status-gate.sh` scopes their writes to `.scrum/pbi/*`. See
FR-019 (requirements.md) and R10 (architecture.md).

### PBI Integrity stage (spawned by Developer at the Round tail)

The five aspect reviewers below **used to run Sprint-end**; they now run
**per-PBI, inside the pipeline**, as the Integrity stage — the final
quality gate before ready-to-merge (kind=code: all 5 after UT Run PASS;
kind=docs: aspects 1 + 5 after impl-review PASS). They are PBI-scoped
(diff bounded by `{base_sha}..{review_sha}` over the PBI's
`paths_touched`), Claude-backed (`model: opus`), and **message-based**:
they have no `Write` tool and return a **markdown** verdict
(`**Verdict: PASS | FAIL**` + a Findings list) as their final assistant
message — **not** the pbi-pipeline JSON envelope (its `criterion_key`
enum is codex-specific). The conductor parses those messages and
synthesizes its own aggregate `.scrum/pbi/<id>/metrics/integrity-r{n}.json`.
Critical/High → revert to `in_progress_impl` (bounded by the `impl_round`
hard cap); Medium/Low recorded, non-blocking. Full protocol:
`skills/pbi-pipeline/references/integrity-stage.md`.

| # | Aspect | Agent | Role | Tools |
|---|---|---|---|---|
| 1 | Requirement conformance | `requirement-conformance-reviewer` | This PBI's AC coverage + scope drift vs. design specs | Read, Grep, Glob, Bash (read-only) |
| 2 | Functional quality | `functional-quality-reviewer` | Boundary values, error propagation, state transitions, data integrity in this PBI's increment | Read, Grep, Glob, Bash (read-only) |
| 3 | Security | `security-reviewer` | OWASP Top 10 / vulnerability scan of this PBI's diff | Read, Grep, Glob, Bash (read-only) |
| 4 | Maintainability | `maintainability-reviewer` | Abstraction, duplication, cohesion, god-class/function, dead code (Pass-A static-analysis-grounded, diff-scoped) | Read, Grep, Glob, Bash (read-only) |
| 5 | Docs consistency | `docs-consistency-reviewer` | `docs/**` vs. implementation drift, stale wording, missing follow-up | Read, Grep, Glob, Bash (read-only) |

The conductor runs a diff-scoped **Pass-A** static analysis (Python
`ruff` / Shell `shellcheck` over the PBI's changed files) before
spawning, writing `.scrum/pbi/<id>/metrics/static-analysis-r{n}.json`
for the maintainability aspect. The whole-repo Pass-B / `vulture`
reachability scan is **not** run here — that `unused_export` class is
the Sprint-end audit's `redundancy` axis. See FR-009.

## Installation

Distributed by `setup-user.sh` from this repo's `agents/` to the
target project's `.claude/agents/`. The `install-subagents` skill
verifies all PBI Pipeline sub-agents are present at PBI start;
missing required sub-agent → BLOCK.
