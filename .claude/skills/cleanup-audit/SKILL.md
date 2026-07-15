---
name: cleanup-audit
description: >
  Multi-agent parallel investigation that finds bugs, drift, dead code,
  redundant docs, and stale references in this repo. Spawns 8 read-only
  sub-agents on independent axes (stale-refs first, then consistency × 3,
  redundancy × 2, dead-artifact × 2), deduplicates findings, classifies
  into 5 tiers, and surfaces user-only decisions. Use after major
  refactors, before releases, or for periodic repo hygiene checks.
disable-model-invocation: false
---

## Inputs

- Repository path (default: cwd — must be the maul-team repo
  root)
- Optional: scope hint string (narrows the consistency-* axes to a
  sub-domain — e.g. "focus on git workflow")
- Optional: extra removed-concept symbols for `stale-refs`. Otherwise
  derived from `git log --oneline -15`.

## Outputs

- Per-axis reports at `/tmp/claude/cleanup-audit/<axis>.md`
- Synthesis at `/tmp/claude/cleanup-audit/SYNTHESIS.md`
- User-facing reply: tier counts + open decisions + recommended
  execution sequence

This skill is **read-only**. NEVER modifies code or docs. Implementation
is a separate phase outside this skill.

## When to use

- After major refactor (schema migration, terminology change, big
  rename) → catch leftovers before they rot
- When you suspect "code is redundant" — this skill verifies whether
  the issue is actually redundancy or hidden drift/bugs (~30% of
  "redundancy" findings are real bugs in practice)
- Pre-release hygiene sweep
- When CLAUDE.md / docs feel out-of-sync with code

## When NOT to use

- Hunting a specific bug → use `superpowers:systematic-debugging` or
  direct `grep`/`Read`
- Implementing a feature → out of scope

## The 8 axes

| Axis | Focus | Output file |
|---|---|---|
| `stale-refs` | Residue of recently removed concepts | `stale-refs.md` |
| `consistency-state` | State schemas / wrapper scripts / guard hook / migration docs | `consistency-state.md` |
| `consistency-agents-skills` | `agents/*.md`, `skills/**/*.md`, `setup-user.sh`, hooks referencing them | `consistency-agents-skills.md` |
| `consistency-workflow` | Git/PBI workflow scripts, quality + completion gates, pipeline skills, related CLAUDE.md prose | `consistency-workflow.md` |
| `redundancy-markdown` | All `.md` (CLAUDE.md, docs/, agents/, skills/) | `redundancy-markdown.md` |
| `redundancy-code` | All shell + Python (excluding `tests/`) | `redundancy-code.md` |
| `dead-hooks` | `hooks/*.sh` + `.claude/settings*.json` registrations + `setup-user.sh` settings template | `dead-hooks.md` |
| `unused-artifacts` | `scripts/`, `agents/`, `skills/` (incl. `references/*.md`) | `unused-artifacts.md` |

The first three "consistency" axes correspond to the user's original
"code-doc consistency by functional domain" axis, partitioned by file
glob to avoid scope overlap.

## Workflow

### Pre-flight

1. Confirm cwd is the maul-team repo root
2. `mkdir -p /tmp/claude/cleanup-audit`
3. `git log --oneline -15` → derive removed-concept hints for
   `stale-refs`. Look for `chore: remove X`, `feat: rename X to Y`,
   `refactor: ...`.
4. `git diff <last-major-merge>..HEAD --stat` → identify which areas
   churned recently

### Step 1 — `stale-refs` first (sequential, blocks others)

Why first: stale references contaminate every consistency axis with
noise. Once `stale-refs` catalogs confirmed-stale + ambiguous symbols,
the other 7 agents skip those known items.

Spawn ONE `general-purpose` sub-agent with the `stale-refs` template
(`references/axes.md`). Wait synchronously. Read its summary section.

### Step 2 — Spawn the other 7 axes in parallel

In a SINGLE message, spawn all 7 sub-agents with `run_in_background:
true`. Each gets:
- The axis-specific prompt from `references/axes.md`
- The `stale-refs` catalog (confirmed-stale + ambiguous lists)
- The common protocol (head of `references/axes.md`)

Wait for all 7 completion notifications.

### Step 3 — Synthesize

1. Read all 8 reports
2. Dedupe overlapping findings (the same item across axes counts once)
3. Classify each distinct finding into 1 of 5 tiers (see
   `references/synthesis.md`):
   - **T1** — Real bugs
   - **T2** — Drift (sub-tiers a/b/c/d)
   - **T3** — Markdown redundancy
   - **T4** — Code redundancy
   - **T5** — Cosmetic
4. Extract **open decisions** (questions only the user can answer)
5. Write `/tmp/claude/cleanup-audit/SYNTHESIS.md`

### Step 4 — Present to user

Reply with:
- Headline: total findings + % real bugs (not redundancy)
- Tier counts
- Open decisions enumerated
- Recommended execution sequence (default: open decisions → T1 → T2
  → T3 → T4 → T5)

Do NOT implement anything in this turn. Implementation is a separate
phase.

## Sequencing of follow-up work

After the user decides on open questions, organize implementation by
file conflict:

- **Same-file findings → sequential**: if T1 items A and B both edit
  `scripts/scrum/merge-pbi.sh`, dispatch in order
- **Disjoint-file findings → parallel**: dispatch concurrently via
  background sub-agents
- **Open-decision batch first**: open-decision resolutions often
  cascade into multiple downstream cleanup items. Resolve them first
  — some T2/T3 items will simply disappear.

## Common pitfalls

1. **Skipping `stale-refs`**: every other axis spends tokens
   re-flagging the same residues. Always run `stale-refs` first.
2. **Axis scope overlap**: `consistency-state` and
   `consistency-workflow` both touch CLAUDE.md if scope is fuzzy.
   Each prompt declares its file globs and forbids edits outside.
3. **"Cleanup-only" framing**: ~30% of findings are real bugs
   masquerading as redundancy. Always classify; never lump everything
   as T3/T4.
4. **Sub-agents accidentally writing**: read-only is enforced by
   prompt only. After each agent, run `git status` and verify clean.
5. **Re-running without prior `stale-refs` catalog**: `stale-refs`
   alone takes ~3-5 min; reuse the previous catalog when re-running.

## References

- `references/axes.md` — common protocol + 8 axis prompt templates
- `references/synthesis.md` — tier classification + dedupe + report
  structure
