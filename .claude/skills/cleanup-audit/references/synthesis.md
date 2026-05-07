# Synthesis: tier classification + dedupe + report structure

The synthesis step reads all 8 axis reports, dedupes overlapping
findings, classifies each distinct issue into 1 of 5 tiers, and
extracts open decisions.

## Tier definitions

### T1 — Real bugs (NOT cleanup; code changes required)

A finding belongs to T1 when:
- A code path is **dead** (cannot fire) but doc claims it does
- Two scripts/skills disagree on a value (vocabulary drift, enum
  mismatch) that breaks runtime behavior
- A guard/regex over-blocks (false positive) or under-blocks (gap)
- Self-contradictory instructions in the same file (e.g. step 1 says
  BLOCK, step 2 says proceed)
- A wrapper bypasses a contract (e.g. raw write where wrapper is
  required)

T1 must be FIXED before any cleanup work. Bundling T1 with T3/T4 PRs
hides the bug under "cosmetic refactor" labels.

### T2 — Drift (schema-impl-doc disagreement; risk-creating)

T2 is the gray zone between bugs and cleanup. Sub-tiers:

- **T2a Wiring gaps**: artifact exists, no caller invokes it. Could
  be a real product gap (writer needed) or dead code (delete).
  Always investigate before deleting.
- **T2b Schema drift**: contracts diverge. Pick one canonical, sync
  others.
- **T2c Doc-claim drift**: doc claims X, code does Y. Update the
  side with weakest authority (usually doc).
- **T2d Stale refs**: leftover symbols from removed concepts (this
  is what `stale-refs` catalogues).

### T3 — Markdown redundancy (cleanup proper)

A finding belongs to T3 when:
- Same content (regulation, list, example) appears verbatim or
  near-verbatim in 3+ Markdown files
- Same point repeated multiple times in one file
- Verbose-but-empty filler

For T3, identify a **canonical home** (usually the most authoritative
file: `docs/data-model.md`, `docs/contracts/`, the executable skill
spec) and replace others with `see <canonical>` links.

T3 should batch by canonical file (one PR per cluster), not one PR
per redundant file. Keeps each PR readable.

### T4 — Code redundancy (cleanup proper)

A finding belongs to T4 when:
- Duplicate functions across files
- Inline-copied helper where a library function exists
- Dead code (functions with no callers, unreachable branches)
- Logging/validation duplication that could share a helper

Confirmed dead code is the highest-leverage T4 work (delete is
risk-free, all consumers verified).

### T5 — Cosmetic

A finding belongs to T5 when:
- Naming inconsistency (file in wrong directory but works)
- Formatting (table vs bullet list, where project rule prefers one)
- Comment style
- Section ordering

T5 is opportunistic. Bundle into PRs that already touch the file.

## Dedupe heuristics

| Overlap pattern | Resolution |
|---|---|
| `stale-refs` + consistency-* flag the same stale symbol | Trust `stale-refs`'s classification; remove from consistency-* |
| `consistency-state` + `consistency-workflow` flag the same drift | Look at file path — assign to whichever axis owns the file primarily |
| `redundancy-markdown` cluster includes a stale ref | Note in cluster: "also stale per stale-refs"; cleanup direction is the same |
| `redundancy-code` dead code overlaps `dead-hooks` unregistered hook | `dead-hooks` wins (hook layer); `redundancy-code` finding folds in |
| `unused-artifacts` zero-reference script is referenced only in deleted-by-OD migration | Drop entirely after OD batch |

After dedupe, the synthesizer should have ~70-85% of raw findings as
distinct items.

## Open decisions (OD)

Questions only the user can answer. Examples:
- "Keep backward-compat enum values, or remove fully?"
- "Is artifact X actually deprecated, or just lacking its caller?"
- "Delete this one-shot migration script now or keep?"

Surface them as a numbered list (`OD-1`, `OD-2`, …). For each:
- Current situation (2 lines)
- 2-3 options with Pro/Con
- Recommendation with reasoning

Do NOT pre-decide for the user. The synthesizer's job is to make the
question crisp, not to answer it.

## Synthesis report structure

Write to `/tmp/claude/cleanup-audit/SYNTHESIS.md`:

```markdown
# Synthesis: Cleanup Audit (<date>)

Source reports: stale-refs, consistency-{state,agents-skills,workflow},
redundancy-{markdown,code}, dead-hooks, unused-artifacts.
Total raw findings: N → after dedupe ~M distinct issues.

## Headline
1-paragraph summary. Lead with the % of findings that are actual bugs
vs cleanup. This is the most important number.

## Tier 1 — Real bugs (N items)
Table: # | Where | What's broken | Why it matters | Source axis

## Tier 2 — Drift (N items)
Sub-grouped by 2a/2b/2c/2d.

## Tier 3 — Markdown redundancy (N clusters)
Numbered clusters: locations + canonical + action.

## Tier 4 — Code redundancy (N items + N dead-code)
Table grouped by category.

## Tier 5 — Cosmetic (N items)
Brief list.

## Open decisions for user (N items)
Numbered: current state + options + recommendation.

## Recommended execution sequence
1. Resolve open decisions
2. T1
3. T2a (wiring gaps — investigate before deleting)
4. T2d (stale refs — quick + low risk)
5. T2b/c
6. T3 (batch by canonical file)
7. T4 (start with dead-code deletes)
8. T5 (opportunistic)
```
