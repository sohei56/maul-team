---
name: cleanup-audit
description: >
  Multi-agent parallel investigation that finds bugs, drift, dead code,
  redundant docs, and stale references in a single sweep. Spawns 8
  read-only sub-agents on independent axes (stale-refs first, then
  code-doc consistency × 3, redundancy × 2, dead-artifact × 2),
  deduplicates findings, classifies into 5 tiers, and surfaces
  user-only decisions. Use after major refactors, before releases, or
  for periodic repo hygiene checks.
disable-model-invocation: false
---

## Inputs

- Repository path (default: current working directory)
- Optional: scope hint string (e.g. "focus on git workflow" — narrows
  axes A1/A3 to a sub-domain)
- Optional: extra removed-concept symbols for D1 (otherwise D1 derives
  them from `git log` of the last 10 commits)

## Outputs

- Per-axis reports at `/tmp/claude/cleanup-audit/{D1,A1,A2,A3,B1,B2,C1,C2}-*.md`
- Synthesis report at `/tmp/claude/cleanup-audit/SYNTHESIS.md`
- User-facing summary: counts per tier + open decisions + recommended
  execution sequence

This skill is **read-only**. It NEVER modifies code or docs. The
follow-up implementation work is a separate phase outside this skill.

## When to use

- After major refactor (schema migration, terminology change, big
  rename) → catch leftovers before they rot
- When you suspect "code is redundant" — this skill verifies whether
  the issue is actually redundancy or hidden drift/bugs (~30% of
  "redundancy" findings are real bugs in practice)
- Pre-release hygiene sweep
- When CLAUDE.md / docs feel out-of-sync with code

## When NOT to use

- Finding a specific bug → use `superpowers:systematic-debugging` or
  direct `grep`/`Read`
- Implementing a feature → out of scope
- Repo < ~3K LOC → 8-axis fan-out is overkill; one or two targeted
  greps suffice

## Workflow

### Pre-flight

1. Confirm working directory matches the repo to audit
2. Create `/tmp/claude/cleanup-audit/`
3. Run `git log --oneline -15` to derive D1's "recently removed
   concepts" hint. Look for `chore: remove X`, `feat: rename X to Y`,
   `refactor: ...` commit messages
4. Run `git diff <last-major-merge>..HEAD --stat` to identify which
   areas of the repo have churned recently

### Step 1: D1 first (sequential, blocks others)

Why D1 first: stale references contaminate every other axis with noise.
If A1 (state schemas) finds a `phase` field reference, was it a real
drift or just a leftover from the recent rename? D1's catalog answers
that question — the other 7 agents can then ignore known-stale items.

Spawn ONE `general-purpose` sub-agent with the D1 prompt template
(`references/axis-templates.md` § D1). Wait synchronously for it to
write `D1-stale-refs.md`. Read its summary section.

### Step 2: Spawn the other 7 axes in parallel

In a SINGLE message, spawn all 7 sub-agents in background mode
(`run_in_background: true`). Each gets:
- The axis-specific prompt from `references/axis-templates.md`
- D1's catalog of confirmed-stale + ambiguous items (so they don't
  re-flag known-stale findings)
- The common protocol from `references/common-protocol.md`

The 7 axes:

| Axis | Focus |
|---|---|
| **A1** | Code-doc consistency in **state management / contracts** |
| **A2** | Code-doc consistency in **agents / skills definitions** |
| **A3** | Code-doc consistency in **git workflow / pipeline** |
| **B1** | Redundancy in **markdown corpus** |
| **B2** | Redundancy in **shell / Python source** |
| **C1** | Dead or ineffective **hooks** |
| **C2** | Unused **scripts / agents / skills** |

Each agent writes its own report file. Wait for all 7 completion
notifications before proceeding.

### Step 3: Synthesize

1. Read all 8 reports
2. Dedupe overlapping findings (e.g., same `phase-gate.sh` stale ref
   may appear in D1 AND A3 — count once)
3. Classify each distinct finding into one of 5 tiers (see
   `references/synthesis-tiers.md`):
   - **T1 — Real bugs**: code does something doc claims it doesn't, or
     the inverse. Not cosmetic.
   - **T2 — Drift**: schema/wrapper/test/script disagreement creating
     risk
   - **T3 — Markdown redundancy**: same content in 3+ places
   - **T4 — Code redundancy**: duplicate functions, inline-copied
     helpers, dead code
   - **T5 — Cosmetic**: layout, naming, formatting
4. Extract **open decisions**: questions only the user can answer
   (e.g. "should we keep field X for backward compat or remove it?")
5. Write synthesis to `SYNTHESIS.md` with tier-by-tier tables, file
   paths, line numbers, proposed actions

### Step 4: Present to user

Reply with:
- Headline: total findings, the % that are real bugs (not redundancy)
- Tier counts
- Open decisions enumerated
- Recommended execution sequence (default: resolve open decisions →
  T1 → T2 → T3 → T4 → T5)

Do NOT implement anything in this turn. Implementation is a separate
phase.

## Sequencing of follow-up work

After user decides on open questions, organize implementation by file
conflict. Two PBI-pipeline-flavored heuristics:

- **Same-file findings → sequential**: if T1 items A and B both edit
  `merge-pbi.sh`, dispatch in order, not parallel
- **Disjoint-file findings → parallel**: dispatch concurrently via
  multiple background sub-agents
- **OD batch first**: open-decision resolutions often cascade into
  multiple downstream cleanup items. Resolve them first; some T2/T3
  items will simply disappear

## Common pitfalls

1. **Skipping D1**: every other axis will spend tokens re-flagging the
   same stale references. Always D1 first.
2. **Letting axes overlap**: A1 and A3 will both touch CLAUDE.md if
   you don't carefully partition scope. Define each axis's file globs
   in the prompt and forbid editing files outside that glob.
3. **Treating it as cleanup-only**: ~30% of findings are real bugs
   masquerading as "redundancy". Always classify — never lump
   everything as "T3/T4 cleanup".
4. **Sub-agents accidentally deleting files**: in past runs, sub-agents
   have over-broadly applied `del(...)` to JSON or struck out
   unintended files. Run `git status` after each agent and verify the
   diff matches stated scope.
5. **Re-running without D1 hints**: D1 alone takes ~3-5 min; re-running
   the whole skill without using a previous D1 catalog wastes
   ~5 sub-agent runs of context.

## Configuration knobs

- For very large repos (>50K LOC), shard A1 by sub-domain (e.g.
  A1a-state, A1b-contracts) instead of one A1 agent
- For repos without external schemas/contracts, drop A1
- For repos with no hooks, drop C1
- The 8 axes are a default that worked well for a Bash + Python +
  Markdown framework repo with hooks and skills. Adjust to your shape.

## References

- `references/axis-templates.md` — full prompt templates for D1 + A1-3 + B1-2 + C1-2
- `references/common-protocol.md` — read-only contract, output format, confidence labels
- `references/synthesis-tiers.md` — tier classification rules + dedupe heuristics
