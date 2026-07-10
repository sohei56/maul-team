# PBI Pipeline Design — Session-Separated Multi-Agent Development Flow

**Status**: Approved (awaiting implementation plan)
**Date**: 2026-05-02
**Owner**: Sohei Inoue
**Replaces**: Existing `design` and `implementation` skills

## Overview

Restructure the per-PBI development workflow so that each phase runs in a
**separate sub-agent session** with **file-based handoff** between sessions.
The Developer agent becomes a pipeline conductor and no longer writes code
itself.

Key properties:

- Black-box UT — UT author never reads implementation source
- Cross-model critical review via Codex CLI for design, implementation,
  and tests
- Deterministic termination gates (no fuzzy heuristics)
- Coverage measured by real tooling (C0/C1 100%, error rate 0%)
- Bidirectional feedback: test failures inform both impl and UT agents
- Parallel PBI execution within a Sprint, with catalog-write contention
  controlled by sprint planning + flock

## 1. Architecture

### 1.1 Sub-agent catalog (6 new)

| Agent | Model | Tools | Role |
|---|---|---|---|
| `pbi-designer` | opus | Read, Write, Edit, Grep, Glob, Bash | Authors PBI working design doc; updates catalog specs as side-effect |
| `codex-design-reviewer` | sonnet | Read, Grep, Glob, Bash | Critical design review via Codex CLI; Claude fallback |
| `pbi-implementer` | opus | Read, Write, Edit, Grep, Glob, Bash | Writes implementation only; test writes blocked by hook |
| `pbi-ut-author` | opus | Read, Write, Edit, Grep, Glob, Bash | Writes tests from design interface only; impl reads blocked by hook |
| `codex-impl-reviewer` | sonnet | Read, Grep, Glob, Bash | Critical impl review (no test code visibility) |
| `codex-ut-reviewer` | sonnet | Read, Grep, Glob, Bash | Critical UT review (no impl code visibility); audits coverage + pragma |

### 1.2 Existing agent impact

- `developer`: role changes from implementer to **PBI pipeline conductor**;
  no longer writes code
- `code-reviewer`, `security-reviewer`, `codex-code-reviewer`: unchanged;
  used by SM at Sprint-end `cross-review`
- `tdd-guide`, `build-error-resolver`: deprioritized (Developer no longer
  writes code); kept as optional sub-agents

### 1.3 Session boundaries

```text
SM session (Agent Teams, long-running)
 └─ Developer session (Agent Teams, long-running) — conductor, drives 1 PBI at a time
     ├─ pbi-designer            (ephemeral, per Round)
     ├─ codex-design-reviewer   (ephemeral)
     ├─ pbi-implementer         (ephemeral, per Round)
     ├─ pbi-ut-author           (ephemeral, per Round)
     ├─ codex-impl-reviewer     (ephemeral)
     └─ codex-ut-reviewer       (ephemeral)
```

State flows entirely through files. Sub-agents have no memory across Rounds.

### 1.4 Skill-level boundary

- **In scope of new pipeline**: per-PBI design → impl+UT → review → done
- **Unchanged**: Sprint planning, catalog stub creation
  (`scaffold-design-spec`), Sprint-end `cross-review`, Sprint Review,
  Retrospective, Integration Sprint
- **Removed**: `skills/design/`, `skills/implementation/`
- **New**: `skills/pbi-pipeline/`, `skills/pbi-escalation-handler/`

## 2. Artifact layout and lifecycle

### 2.1 PBI working directory

```text
.scrum/pbi/<pbi-id>/
  state.json                # PBI internal state
  design/
    design.md               # Primary artifact (pbi-designer)
    review-r{n}.md          # Codex design review per round
  impl/
    review-r{n}.md          # Codex impl review per round
    summary.md              # Final-round summary (file list, change summary)
  ut/
    review-r{n}.md          # Codex UT review per round
    summary.md
  metrics/
    coverage-r{n}.json      # Normalized coverage data
    test-results-r{n}.json  # Normalized test results
    pragma-audit-r{n}.json  # pragma exclusions + reasons
  feedback/
    impl-r{n}.md            # Aggregated FB for next-round impl agent
    ut-r{n}.md              # Aggregated FB for next-round UT agent
  pipeline.log              # 1 line per phase event
```

Implementation source and test source live at the project's normal paths
(`src/`, `tests/`, etc.), not in `.scrum/pbi/`.

### 2.2 Round numbering

- `-r{N}` suffix where N = round number (1..5)
- Design phase and impl+UT phase have **independent** round counters
- Per-Round inputs: latest review only + previous-Round summary
  (no full-Round-history accumulation)

### 2.3 PBI internal state.json

```json
{
  "pbi_id": "pbi-001",
  "phase": "design | impl_ut | complete | escalated",
  "design_round": 0,
  "impl_round": 0,
  "design_status": "pending | in_review | fail | pass",
  "impl_status": "pending | in_review | fail | pass",
  "ut_status": "pending | in_review | fail | pass",
  "coverage_status": "pending | fail | pass",
  "escalation_reason": null,
  "started_at": "...",
  "updated_at": "..."
}
```

`escalation_reason` enum (set when `phase: escalated`):

```text
stagnation | divergence | max_rounds | budget_exhausted |
requirements_unclear | coverage_tool_error | coverage_tool_unavailable |
catalog_lock_timeout
```

PBI complete: `design_status`, `impl_status`, `ut_status`,
`coverage_status` all `pass`.

### 2.4 Archive policy

Initially: **keep everything** under `.scrum/pbi/<pbi-id>/` after PBI
completes. Future may compact to summaries-only.

`.scrum/pbi/` is gitignored. PBI design docs are not persisted to
`docs/design/specs/pbi/` — catalog specs are the single source of truth
for permanent design knowledge.

## 3. Pipeline flow

### 3.1 Top-level conductor flow

```text
PBI received from SM
  ↓
Initialize (.scrum/pbi/<pbi-id>/, state.json)
  ↓
Design Phase (Rounds 1..5) → see 3.2
  ↓
Impl+UT Phase (Rounds 1..5) → see 3.3
  ↓
Completion or Escalation
```

### 3.2 Design phase Round structure

```text
Round n:
  Step 1  Spawn pbi-designer
            inputs: PBI details, requirements, related catalog specs (read-only),
                    catalog-config.json, prior review-r{n-1}.md (if n>=2)
            output: .scrum/pbi/<pbi-id>/design/design.md
  Step 2  Spawn codex-design-reviewer
            inputs: design.md, related catalog specs, requirements
            output: .scrum/pbi/<pbi-id>/design/review-r{n}.md
  Step 3  Evaluate termination gates (see 3.4)
            success → phase=impl_ut, impl_round=0
            stagnation/divergence/max_rounds → phase=escalated → SM
            other FAIL → review-r{n}.md becomes input to Round n+1
```

### 3.3 Impl+UT phase Round structure

```text
Round n:
  Step 1  Spawn pbi-implementer + pbi-ut-author IN PARALLEL
            implementer inputs: design.md, prior feedback/impl-r{n}.md (if n>=2)
                          output: implementation source files
                          constraint: no test-file writes (path-guard hook)
            ut-author inputs: design.md, prior feedback/ut-r{n}.md (if n>=2),
                              prior coverage-r{n-1}.json (if n>=2)
                       output: test files
                       constraint: no impl-file reads/writes (path-guard hook)
  Step 2  Run tests + measure coverage (Developer via Bash)
            uses .scrum/config.json (see 6.1) test_runner + coverage_tool
            normalizes outputs to common JSON schemas (see 6.4, 6.5)
            generates pragma-audit-r{n}.json (see 6.6)
            tool-launch failure → escalate (coverage_tool_error)
  Step 3  Spawn codex-impl-reviewer + codex-ut-reviewer IN PARALLEL
            impl-reviewer inputs: design.md, impl source files only,
                                  requirements
                          output: impl/review-r{n}.md
            ut-reviewer inputs: design.md, test files only,
                                coverage-r{n}.json, pragma-audit-r{n}.json,
                                requirements
                        output: ut/review-r{n}.md
  Step 4  Aggregate + judge + (if FAIL) build feedback
            evaluate Pass criteria (see 6.7)
            evaluate termination gates (see 3.4)
            success → phase=complete → completion (3.5)
            stagnation/divergence/max_rounds → phase=escalated → SM
            other FAIL → write feedback/impl-r{n+1}.md and feedback/ut-r{n+1}.md
                         per FB routing matrix (see 3.6) → Round n+1
```

### 3.4 Termination gates (deterministic)

Composite gate model (Anthropic + Ralph + GAN-derived):

| Gate | Condition | Outcome |
|---|---|---|
| Success | All reviewer verdicts PASS ∧ test failures=0 ∧ exec errors=0 ∧ uncaught=0 ∧ C0=100% ∧ C1=100% (with valid pragma exemptions) | STOP success |
| Stagnation | Same `finding_signature` repeats in 2 consecutive Rounds | STOP escalate (`stagnation`) |
| Divergence | (CRITICAL+HIGH count) increases Round n → n+1 | STOP escalate (`divergence`) |
| Hard cap | round_n ≥ 5 | STOP escalate (`max_rounds`) |
| Budget cap | (future) cumulative token > threshold | STOP escalate (`budget_exhausted`) |

Each finding's `signature` field (see envelope schema in 4.1) format:

```text
{file_path}:{line_start}-{line_end}:{criterion_key}
```

`criterion_key` is a fixed enum (see 4.1). Stagnation detection is
exact string equality across consecutive Rounds — no similarity
heuristic.

The design phase uses the same gates with the success condition replaced
by `design-reviewer = PASS`.

### 3.5 PBI completion

On `phase: complete`, Developer:

1. Update `backlog.json`: status → `done`
2. Add `pipeline_summary` (round counts, final coverage)
3. Notify SM via Agent Teams:
   `[pbi-001] PASS. design_rounds=2 impl_rounds=3 c0=100 c1=100`
4. Wait for next PBI assignment

### 3.6 Feedback routing matrix

| Source | impl agent | UT agent |
|---|---|---|
| impl-reviewer findings | ✓ | – |
| ut-reviewer findings | – | ✓ |
| Test failures (assertion / exec error / uncaught) | ✓ | ✓ |
| Coverage gap — branch unreachable from tests | – | ✓ |
| Coverage gap — implementation dead code | ✓ | – |

Test failures are sent to **both** with role-specific framing:

- impl: "verify your code matches design, assuming tests are correct"
- UT: "verify your tests match design interface, assuming impl is correct"

Role separation (impl writes only source; UT writes only tests) prevents
write conflicts.

Dead-code detection (Developer-side, see 6.8): grep for known markers
(`raise NotImplementedError`, `panic!()`, `unreachable!()`, constant-false
branches). Indeterminate cases route to both agents.

### 3.7 Parallel PBI execution

Multiple Developers run independent PBI pipelines in parallel within one
Sprint. `.scrum/pbi/<pbi-id>/` directories are fully isolated.

Catalog write contention (3-layer defense):

1. **Sprint planning pre-separation**: SM records `catalog_targets[]` per
   PBI in `backlog.json`. Overlapping PBIs are sequenced on one Developer,
   not parallel-assigned.
2. **Runtime exclusion** (backstop): pbi-designer acquires
   `flock(2)` on `.scrum/locks/catalog-{spec_id}.lock` before catalog
   writes; 60-second timeout → `escalation_reason: catalog_lock_timeout`.
3. **Conflict detection** (last resort): mtime check after edit; if
   another PBI wrote in between, discard and retry.

### 3.8 SM escalation handling (in scope)

When Developer escalates, SM invokes new `pbi-escalation-handler` skill.

| `escalation_reason` | SM action |
|---|---|
| `stagnation` | Extract findings → present to user with options [split / redesign / hold] |
| `divergence` | Same as stagnation, marked urgent (rollback is future work) |
| `max_rounds` | If findings trend was decreasing, propose 1-time retry with fresh Developer; else human-escalate |
| `budget_exhausted` | Immediate human-escalate |
| `requirements_unclear` | SM consults PO via clarification ticket; Developer resumes after answer |
| `coverage_tool_unavailable` | Surface install instruction; PBI on hold |
| `catalog_lock_timeout` | Check who holds lock; if dead session, force-release; else human-escalate |

## 4. Sub-agent definitions

### 4.1 Common: schema-first output envelope

All sub-agents emit a JSON envelope as the final markdown code block:

```json
{
  "status": "pass | fail | error",
  "summary": "one-line",
  "verdict": "PASS | FAIL | null",
  "findings": [
    {
      "signature": "src/auth.py:42-58:incorrect_behavior",
      "severity": "critical | high | medium | low",
      "criterion_key": "incorrect_behavior",
      "file_path": "src/auth.py",
      "line_start": 42,
      "line_end": 58,
      "description": "..."
    }
  ],
  "next_actions": ["..."],
  "artifacts": [".scrum/pbi/pbi-001/design/design.md"]
}
```

`criterion_key` enum (additions require this design's amendment, not
ad-hoc extension):

```text
# design review
missing_requirement, scope_creep, unclear_interface,
inconsistent_with_catalog, inconsistent_internal, missing_error_handling

# impl review
incorrect_behavior, scope_creep, naming, error_handling,
missing_validation, unclear_intent, dead_code, duplication

# UT review
missing_test_for_acceptance, missing_branch_coverage, redundant_test,
mock_overuse, magic_number, bad_assertion, pragma_unjustified
```

### 4.2 Agent-by-agent specs

#### pbi-designer

```yaml
name: pbi-designer
model: opus
effort: high
maxTurns: 100
tools: [Read, Write, Edit, Grep, Glob, Bash]
disallowedTools: [WebFetch, WebSearch]
```

Inputs: PBI details, requirements, related catalog specs (read-only),
catalog-config, prior review (if any).
Output: `.scrum/pbi/<pbi-id>/design/design.md`.
Side effect: may update `docs/design/specs/**/*.md` (catalog) when PBI
touches existing components.

Required design doc sections:

1. Scope (components touched)
2. Components (responsibilities per component)
3. Business Logic (behavior, sequences, state transitions)
4. Interfaces (signatures + I/O contracts + error conditions)
5. Catalog Updates (catalog spec deltas with summary)
6. Test Strategy Hints (boundaries, edge cases — no implementation)

Forbidden: implementation code examples (interface declarations are OK);
writes outside `.scrum/pbi/` and `docs/design/specs/`.

#### codex-design-reviewer

```yaml
name: codex-design-reviewer
model: sonnet
effort: medium
maxTurns: 30
tools: [Read, Grep, Glob, Bash]
```

Reviews PBI design doc + catalog deltas via Codex CLI. Falls back to
Claude review when Codex unavailable. Review criteria: completeness,
internal consistency, catalog consistency, interface clarity, scope.

#### pbi-implementer

```yaml
name: pbi-implementer
model: opus
effort: high
maxTurns: 150
tools: [Read, Write, Edit, Grep, Glob, Bash]
disallowedTools: [WebFetch, WebSearch]
```

Path constraints (enforced via PreToolUse hook):

- Write/Edit allowed: implementation paths (project-specific) and
  `.scrum/pbi/`
- Write/Edit blocked: test paths

Prompt rules: no test-file writes; do not edit design docs (raise concerns
as findings); avoid unnecessary defensive code (interferes with C1=100%).

#### pbi-ut-author

```yaml
name: pbi-ut-author
model: opus
effort: high
maxTurns: 150
tools: [Read, Write, Edit, Grep, Glob, Bash]
disallowedTools: [WebFetch, WebSearch]
```

Path constraints (enforced strictly):

- Read/Write/Edit allowed: test paths, design doc, `.scrum/pbi/`,
  declaration-only files (e.g., `.d.ts`, `.pyi`)
- Read/Write/Edit blocked: implementation paths (`src/` etc.)

Prompt rules: write tests from `Interfaces` section only; assume impl may
not exist (black-box tests); one test per acceptance criterion + per
branch; AAA pattern; pragma exclusions require inline-comment reason.

#### codex-impl-reviewer

```yaml
name: codex-impl-reviewer
model: sonnet
effort: medium
maxTurns: 30
tools: [Read, Grep, Glob, Bash]
```

Reviews implementation source against design (no test visibility) via
Codex CLI. Criteria: interface match, business logic correctness, scope,
quality.

#### codex-ut-reviewer

```yaml
name: codex-ut-reviewer
model: sonnet
effort: medium
maxTurns: 30
tools: [Read, Grep, Glob, Bash]
```

Reviews tests + coverage report against design (no impl visibility) via
Codex CLI. Criteria: interface coverage, pragma justification, branch
coverage gap interpretation, test quality.

### 4.3 Path-level enforcement

`hooks/pre-tool-use-path-guard.sh` (PreToolUse hook):

- Reads payload (tool_name, tool_input.file_path, agent_name)
- For `pbi-ut-author`: blocks Read/Write/Edit on impl paths
- For `pbi-implementer`: blocks Write/Edit on test paths
- Patterns from `.scrum/config.json.path_guard`
- exit 2 + stderr message → blocks tool

Fallback when agent_name is unavailable: prompt-level convention +
ut-reviewer detects suspicious cross-references in test files.

### 4.4 Codex CLI invocation shared library

`hooks/lib/codex-invoke.sh` provides `codex_review_or_fallback()`. All
three Codex reviewers source it. Returns non-zero when Codex unavailable;
caller falls back to Claude review.

### 4.5 Modified developer.md

```yaml
name: developer
model: opus
effort: high
maxTurns: 200
keep-coding-instructions: true
memory: project
disallowedTools: [WebFetch, WebSearch]
skills:
  - requirements-sprint
  - pbi-pipeline       # NEW (replaces design + implementation)
  - install-subagents
  - smoke-test
```

Description and lifecycle text rewritten to reflect conductor role.

## 5. Skill structure

### 5.1 New skill: `pbi-pipeline`

Progressive disclosure pattern (Anthropic-recommended): one orchestrator
SKILL.md plus `references/` for phase details.

```text
skills/pbi-pipeline/
  SKILL.md                          ~150 lines (navigation + decision gates)
  references/
    phase1-design.md                ~120 lines
    phase2-impl-ut.md               ~150 lines
    coverage-gate.md                ~100 lines
    feedback-routing.md             ~80 lines
    termination-gates.md            ~100 lines
    sub-agent-prompts.md            ~200 lines (schema-first templates)
    state-management.md             ~80 lines
    catalog-contention.md           ~80 lines
```

`SKILL.md` body holds inputs/outputs, phase navigation table, and lazy
references. Each `references/*.md` is loaded only when the conductor
enters the corresponding phase.

### 5.2 New skill: `pbi-escalation-handler`

```text
skills/pbi-escalation-handler/SKILL.md   ~100 lines
```

Used by SM when Developer escalates. Implements the response matrix
in 3.8. Records decision in `.scrum/pbi/<pbi-id>/escalation-resolution.md`.

### 5.3 Removed skills

- `skills/design/SKILL.md` → deleted (functionality moved to pbi-pipeline
  phase 1)
- `skills/implementation/SKILL.md` → deleted (functionality moved to
  pbi-pipeline phase 2)

### 5.4 Modified skills

- `skills/install-subagents/SKILL.md`: adds 6 new sub-agents to required
  list; tdd-guide / build-error-resolver moved to optional.
- `skills/sprint-planning/SKILL.md`: adds catalog_targets pre-separation
  step (3-layer defense first line).
- `skills/cross-review/SKILL.md`: clarifies role as Sprint-end
  cross-cutting quality gate; references PBI pipeline final reviews as
  input pointers.

### 5.5 File summary

New (18 files):

- 6 agent definitions (`agents/pbi-*.md` x3, `agents/codex-*-reviewer.md` x3)
- 1 `skills/pbi-pipeline/SKILL.md`
- 8 `skills/pbi-pipeline/references/*.md`
- 1 `skills/pbi-escalation-handler/SKILL.md`
- 1 `hooks/pre-tool-use-path-guard.sh`
- 1 `hooks/lib/codex-invoke.sh`

Modified (5 files): `agents/developer.md`, `agents/scrum-master.md`,
`skills/install-subagents/SKILL.md`, `skills/sprint-planning/SKILL.md`,
`skills/cross-review/SKILL.md`.

Deleted (2 files): `skills/design/SKILL.md`,
`skills/implementation/SKILL.md`.

Plus `.scrum/config.json` schema extension and `.claude/settings.json`
hook registration.

## 6. Coverage measurement integration

### 6.1 `.scrum/config.json` extension

```json
{
  "test_runner": {
    "command": "pytest",
    "args": ["--tb=short", "-q"],
    "results_format": "junit",
    "results_path_template": ".scrum/pbi/{pbi_id}/metrics/test-results-r{round}.xml"
  },
  "coverage_tool": {
    "command": "coverage",
    "run_args": ["run", "--branch", "--source=src", "-m", "pytest"],
    "report_args": ["json", "-o"],
    "report_path_template": ".scrum/pbi/{pbi_id}/metrics/coverage-r{round}.json",
    "supports_branch": true
  },
  "pragma_pattern": "pragma: no cover",
  "path_guard": {
    "impl_globs": ["src/**", "lib/**"],
    "test_globs": ["tests/**", "**/*_test.py"]
  }
}
```

PBI design doc may override `test_runner` / `coverage_tool` by including
a fenced YAML block in its `Test Strategy Hints` section:

````markdown
## Test Strategy Hints

(boundaries, edge cases, etc.)

```yaml runtime-override
test_runner:
  command: pytest
  args: ["-q", "tests/specific_module/"]
coverage_tool:
  command: coverage
  run_args: ["run", "--branch", "--source=src/specific_module", "-m", "pytest"]
```
````

Developer parses any `yaml runtime-override` fenced block, deep-merges over
the project default, and uses the merged config for that PBI only. Other
PBIs are unaffected.

### 6.2 Reference language matrix (in `coverage-gate.md`)

| Language | Test runner | Coverage tool | C1 support |
|---|---|---|---|
| Python | pytest | coverage.py `--branch` | yes |
| TypeScript | vitest | c8 `--all --branches` | yes (c8 0.7+) |
| Go | `go test` | go test -covermode=count + gocov-xml | C0 only by default |
| Rust | cargo test | cargo-llvm-cov (`--mcdc`) | partial |
| Java | JUnit | JaCoCo (`branch=true`) | yes |
| Bash | bats | bashcov | partial |

For partial-C1 languages, `.scrum/config.json` must declare relaxed
threshold explicitly (e.g., `c1_threshold: 0.95`); ad-hoc relaxation
forbidden.

### 6.3 Developer measurement sequence (impl phase Step 2 detail)

```text
(a) test+coverage run
    cmd_run = coverage_tool.command + run_args
    nonzero exit → recorded as failures (still proceed to (b)/(c))
    tool-launch error → escalate (coverage_tool_error)
(b) coverage report generation
    cmd_report = coverage_tool.command + report_args + path
(c) normalize raw output → common schema (6.4) → overwrite path
(d) normalize test results (junit/json) → common schema (6.5)
(e) pragma audit → pragma-audit-r{n}.json (6.6)
```

### 6.4 Common coverage JSON schema

```json
{
  "round": 1,
  "pbi_id": "pbi-001",
  "tool": "coverage.py",
  "tool_version": "7.4.0",
  "measured_at": "2026-05-02T12:30:00+09:00",
  "totals": {
    "c0": {"covered": 245, "total": 248, "percent": 98.79},
    "c1": {"covered": 87, "total": 92, "percent": 94.57, "supported": true}
  },
  "files": [
    {
      "path": "src/auth.py",
      "c0": {"covered": 42, "total": 45, "percent": 93.33},
      "c1": {"covered": 18, "total": 20, "percent": 90.0, "supported": true},
      "uncovered_lines": [55, 56, 87],
      "uncovered_branches": [
        {"line": 32, "from": 32, "to": 35, "condition": "false"}
      ],
      "pragma_excluded_lines": [120, 121]
    }
  ]
}
```

### 6.5 Common test-results schema

```json
{
  "round": 1,
  "pbi_id": "pbi-001",
  "tool": "pytest",
  "tool_version": "8.0.0",
  "executed_at": "2026-05-02T12:30:00+09:00",
  "totals": {
    "tests": 47, "passed": 45, "failed": 2,
    "exec_errors": 0, "uncaught_exceptions": 0, "skipped": 0
  },
  "failures": [
    {
      "test_id": "tests/test_auth.py::test_invalid_token",
      "type": "assertion | exec_error | uncaught_exception | timeout",
      "file_path": "tests/test_auth.py",
      "line": 78,
      "message": "...",
      "stack_trace": "..."
    }
  ]
}
```

### 6.6 Common pragma-audit schema

```json
{
  "round": 1,
  "pbi_id": "pbi-001",
  "audited_at": "2026-05-02T12:30:00+09:00",
  "exclusions": [
    {
      "file_path": "src/auth.py",
      "line": 120,
      "code_excerpt": "raise UnreachableError()  # pragma: no cover",
      "reason_text": "Defensive guard...",
      "reason_source": "comment_above | comment_inline | missing"
    }
  ]
}
```

`reason_source: missing` → automatic FAIL at ut-reviewer.

### 6.7 Pass evaluation (Developer impl phase Step 4)

```text
ALL of:
  test_results.totals.failed == 0
  test_results.totals.exec_errors == 0
  test_results.totals.uncaught_exceptions == 0
  coverage.totals.c0.percent >= c0_threshold (default 100.0)
  if c1.supported: coverage.totals.c1.percent >= c1_threshold (default 100.0)
  no pragma exclusion has reason_source == "missing"
  impl-reviewer.verdict == PASS
  ut-reviewer.verdict == PASS
```

### 6.8 Dead-code detection (FB routing)

Developer greps uncovered branches for known markers:
`raise NotImplementedError`, `panic!()`, `unreachable!()`,
constant-false comparisons → impl dead code (route to impl).
Other cases → test gap (route to UT).
Indeterminate → both.

### 6.9 Tool unavailability fallback

Coverage tool not installed → no install attempt; immediate escalation
(`coverage_tool_unavailable`). SM escalation handler surfaces install
instructions to user.

### 6.10 Coverage skip

Project-wide skip allowed when coverage tool not available for the
language (e.g., pure shell script PBIs):

- `.scrum/config.json` declares `coverage_tool: null` → skip declaration
- design doc preamble must record reason
- codex-design-reviewer enforces reason existence

This is a project-wide explicit exemption, not a per-PBI decision.

## 7. State management and hooks

### 7.1 State file map

```text
.scrum/
  state.json                    extended phase enum
  sprint.json                   extended developers[].current_pbi*
  backlog.json                  extended catalog_targets, pipeline_summary
  config.json                   extended (see 6.1)
  dashboard.json                extended pbi_pipelines section
  communications.json           unchanged
  session-map.json              unchanged
  locks/                        NEW: catalog flock area
  pbi/<pbi-id>/                 NEW: per-PBI workspace (see 2.1)
```

### 7.2 `.scrum/state.json` extension

Adds `phase: "pbi_pipeline_active"` (replaces former `design` and
`implementation` phases for new flow). Old enum values retained for
backward-compatible read paths only.

```json
{
  "phase": "...|pbi_pipeline_active",
  "current_sprint": "sprint-002",
  "active_pbi_pipelines": ["pbi-001", "pbi-003"]
}
```

### 7.3 `.scrum/sprint.json` extension

```json
{
  "developers": [
    {
      "id": "dev-001-s2",
      "assigned_pbis": ["pbi-001", "pbi-003"],
      "current_pbi": "pbi-001",
      "current_pbi_phase": "design | impl_ut | complete | escalated",
      "sub_agents": [...]
    }
  ]
}
```

### 7.4 `.scrum/backlog.json` extension

```json
{
  "items": [
    {
      "id": "pbi-001",
      "status": "...|blocked",
      "catalog_targets": ["docs/design/specs/api/auth.md"],
      "pipeline_summary": {
        "design_rounds": 2,
        "impl_rounds": 3,
        "final_c0": 100.0,
        "final_c1": 100.0,
        "final_test_count": 47,
        "completed_at": "...",
        "escalation_reason": null
      }
    }
  ]
}
```

### 7.5 Existing hook impact

| Hook | Change |
|---|---|
| `phase-gate.sh` | Add `pbi_pipeline_active` phase; permit new sub-agent writes; restrict catalog writes to pbi-designer |
| `completion-gate.sh` | Add completion check for `pbi_pipeline_active` (all active pipelines complete or escalated) |
| `dashboard-event.sh` | Recognize new sub-agent events; add `pbi_id` field; populate `dashboard.json.pbi_pipelines` (schema in 7.8) |
| `quality-gate.sh` | Unchanged |
| `session-context.sh` | Inject `SCRUM_PBI_ID` env into sub-agent sessions |
| `stop-failure.sh` | Unchanged |

### 7.6 New hooks

`hooks/pre-tool-use-path-guard.sh` — see 4.3.

Registration in `.claude/settings.json` (target project, applied by
`setup-user.sh`):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Read|Write|Edit",
        "command": ".claude/hooks/phase-gate.sh" },
      { "matcher": "Read|Write|Edit",
        "command": ".claude/hooks/pre-tool-use-path-guard.sh" }
    ]
  }
}
```

Order matters: phase-gate first, then path-guard.

### 7.7 Catalog flock

`.scrum/locks/catalog-{spec_id}.lock` where `{spec_id}` =
spec path with `/` → `_`. 60-second timeout; timeout →
`escalation_reason: catalog_lock_timeout`.

### 7.8 TUI dashboard impact

`dashboard.json.pbi_pipelines` schema (populated by `dashboard-event.sh`):

```json
{
  "events": [...],
  "pbi_pipelines": [
    {
      "pbi_id": "pbi-001",
      "developer": "dev-001-s2",
      "phase": "design | impl_ut | complete | escalated",
      "round": 2,
      "active_subagents": ["pbi-implementer", "pbi-ut-author"],
      "last_event_at": "2026-05-02T13:45:00+09:00"
    }
  ]
}
```

Add **PBI Pipeline pane** rendering this section:

- PBI id, Developer id, current phase, round number, active sub-agents,
  last update timestamp
- Escalated PBIs styled distinctly

Existing watchdog-based file-change detection covers it. New
`pbi_pipeline_active` phase rendered as "PBI Pipelines Running".

### 7.9 hooks/lib

Adds `hooks/lib/codex-invoke.sh` (Codex CLI shared invocation).

### 7.10 `setup-user.sh`

Extends copy targets to include the 18 new files (see 5.5) plus
`.claude/settings.json` hook registration update. Underlying copy +
JSON merge logic unchanged.

## 8. Migration plan and out of scope

### 8.1 Migration approach

Clean break, not staged co-existence. Old `design` and `implementation`
skills are deleted (saved to `skills/legacy/` if needed for the migration
window). State enum old values kept read-only for dashboard
backward compat.

### 8.2 In-flight PBI handling

In-progress Sprints complete on the old flow. Next Sprint adopts new
flow at Sprint Planning (records `catalog_targets`, conductor invokes
`pbi-pipeline`).

Migration guide: `docs/MIGRATION-pbi-pipeline.md` documents concept
mapping (`docs/design/specs/` ↔ `.scrum/pbi/<pbi-id>/design/`).

### 8.3 Test strategy

#### Unit (bats)

- `test_path_guard_hook.bats` — path-guard logic
- `test_codex_invoke.bats` — Codex invocation + fallback
- `test_phase_gate_pbi_pipeline.bats` — phase-gate extension
- `test_state_management.bats` — PBI state.json operations
- Old `test_design_*.bats` etc. removed; rewritten for new skills

#### Lint (bats)

shellcheck for new hooks/scripts.

#### Integration (bats)

- `test_pbi_pipeline_happy_path.bats` — single PBI, 1 Round to complete
- `test_pbi_pipeline_escalation.bats` — stagnation gate triggers escalate
- `test_pbi_parallel.bats` — 2 PBIs parallel with catalog flock contention

Codex CLI mocked via `CODEX_CMD_OVERRIDE=tests/fixtures/fake-codex.sh`.

#### Manual smoke

`tests/manual/smoke-pbi-pipeline.md` documents the full live-execution
walkthrough (used until Claude Code API mocking matures).

### 8.4 Documentation

Updates: README, `docs/quickstart.md`, `docs/architecture.md`,
`CLAUDE.md`, plus migration guide and JSON Schema additions in
`docs/contracts/` (envelope, coverage, test-results, pragma-audit).

### 8.5 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Codex unavailable → Claude fallback loses cross-model independence | Med | Warning log + Sprint-end cross-review; future alternative model CLIs |
| C1=100% unattainable for some languages | Med | Required `config.json` exemption + reason in design + reviewer enforcement |
| Catalog flock timeouts | Med | Sprint planning pre-separation as primary defense |
| path-guard hook fails to detect agent name | High | Conductor self-test at PBI start (dummy Read) |
| Complex PBI fails to converge in 5 Rounds | Med | SM escalation matrix offers PBI split |
| Old vs new design-doc location confusion | Med | Migration guide + CLAUDE.md summary |
| Sub-agent spawn latency (dozens per PBI) | Med | Sonnet for reviewers + parallel spawn; budget cap is future work |

### 8.6 Out of scope (future work)

1. Token/cost budget enforcement (`budget_exhausted` gate placeholder)
2. GAN-style rollback on divergence
3. Alternative model CLIs (Gemini, OpenAI direct) beyond Codex+Claude
4. Real-time intervention UI (manual abort/skip mid-Round)
5. Cross-Developer sub-agent learning/pattern sharing
6. ML-driven `catalog_targets` auto-inference from PBI text
7. Integration Sprint defect-fix loop integrated with PBI pipeline
8. Automatic change-process trigger from inside PBI pipeline
9. Integration with `ralphinho-rfc-pipeline` and other autonomous loop
   patterns at Sprint level

### 8.7 Implementation sequence (handoff to writing-plans)

Rough dependency order:

1. Foundation: `.scrum/config.json` schema, `hooks/lib/codex-invoke.sh`,
   `hooks/pre-tool-use-path-guard.sh`
2. Agent definitions: 6 sub-agents, modified `developer.md` and
   `scrum-master.md`
3. Skill definitions: `pbi-pipeline/`, `pbi-escalation-handler/`,
   modified `install-subagents` / `sprint-planning` / `cross-review`
4. Existing hook modifications
5. Old skill deletions (after new flow validated)
6. TUI extension (`dashboard/app.py` PBI Pipeline pane)
7. Tests (bats unit / lint / integration / manual smoke)
8. Documentation (migration guide, architecture, quickstart, CLAUDE.md)
9. `setup-user.sh` extension

writing-plans will expand each step into concrete tasks.
