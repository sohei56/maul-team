# Synthesis: tier classification + dedupe

The synthesis step reads all 8 axis reports, dedupes overlapping
findings, classifies each distinct issue into one of 5 tiers, and
extracts open decisions.

## Tier definitions

### T1 — Real bugs (NOT cleanup; code changes required)

A finding belongs to T1 when:
- A code path is **dead** (cannot fire) but doc claims it does
- Two scripts/skills disagree on a value (vocabulary drift,
  enum-vs-enum mismatch) that breaks runtime behavior
- A guard/regex over-blocks (false positive) or under-blocks (gap)
- Self-contradictory instructions in the same file (e.g. step 1 says
  BLOCK, step 2 says proceed)
- A wrapper bypasses a contract (e.g. raw write where wrapper is
  required)

T1 should be FIXED before any cleanup work. Bundling T1 with T3/T4
PRs hides the bug under "cosmetic refactor" labels.

### T2 — Drift (schema-impl-doc disagreement; risk-creating)

T2 is the gray zone between bugs and cleanup:
- Schema field exists, no writer (or vice versa)
- Doc describes field that schema doesn't have
- Wrapper accepts vocabulary the schema rejects
- Hook registered but matcher targets a tool that doesn't exist

Sub-tiers:
- **T2a Wiring gaps**: artifact exists, no caller invokes it. Could
  be a real product gap (writer needed) or dead code (delete).
  Always investigate before deleting.
- **T2b Schema drift**: contracts diverge. Pick one canonical, sync
  others.
- **T2c Doc-claim drift**: doc claims X, code does Y. Update the
  side with weakest authority (usually doc).
- **T2d Stale refs**: leftover symbols from removed concepts (this
  is what D1 catalogs).

### T3 — Markdown redundancy (cleanup proper)

A finding belongs to T3 when:
- Same content (regulation, list, example) appears verbatim or
  near-verbatim in 3+ Markdown files
- Same point repeated multiple times in one file
- Verbose-but-empty: filler that adds tokens without information

For T3, identify a **canonical home** (usually the most authoritative
file: `data-model.md`, `docs/contracts/`, the executable skill spec)
and replace others with `see <canonical>` links.

T3 should batch by canonical file (one PR per cluster), not one PR
per redundant file. That keeps each PR readable.

### T4 — Code redundancy (cleanup proper)

A finding belongs to T4 when:
- Duplicate functions across files
- Inline-copied helper where a library function exists
- Dead code (functions with no callers, unreachable branches)
- Logging/validation duplication that could share a helper

Confirmed dead code is the highest-leverage T4 work (delete is risk-
free, all consumers verified).

### T5 — Cosmetic

A finding belongs to T5 when:
- Naming inconsistency (file in wrong directory, but works)
- Formatting (table vs bullet list, where project rule prefers one)
- Comment style
- Section ordering

T5 is opportunistic. Bundle into PRs that already touch the file for
other reasons.

## Dedupe heuristics

Findings often overlap across axes. Rules of thumb:

| Overlap pattern | How to dedupe |
|---|---|
| D1 + Ax flag the same stale symbol | Trust D1's classification; remove from Ax |
| A1 + A3 flag the same drift | Look at file path — assign to whichever axis owns the file primarily |
| B1 cluster includes a stale ref D1 found | Note in B1 cluster: "also stale per D1"; cleanup direction is the same |
| B2 dead code overlaps C1 unregistered hook | C1 wins (hook layer); B2 finding folds in |
| C2 zero-reference script is referenced only in deleted-by-OD migration | Drop entirely after OD batch |

After dedupe, the synthesizer should have ~70-85% of raw findings as
distinct items.

## Open decisions

These are questions only the user can answer. They look like:
- "Should we keep backward-compat enum values, or fully remove?"
- "Is artifact X actually deprecated, or just lacking its caller?"
- "Should this one-shot migration script be deleted now or kept?"

Surface them as a numbered list (`OD-1`, `OD-2`, …). For each:
- State current situation in 2 lines
- Enumerate 2-3 options with Pro/Con
- Provide a recommendation with reasoning

Do NOT pre-decide for the user. The synthesizer's job is to make the
question crisp, not to answer it.

## Synthesis report structure

```markdown
# Synthesis: Cleanup Audit (<date>)

Source reports: D1, A1-3, B1-2, C1-2
Total raw findings: N → after dedupe ~M distinct issues.

## Headline
1-paragraph summary. Lead with the % of findings that are actual bugs
vs cleanup. This is the most important number.

## Tier 1 — Real bugs (N items)
Table with columns: # | Where | What's broken | Why it matters | Source axis

## Tier 2 — Drift (N items)
Sub-grouped by 2a/2b/2c/2d.

## Tier 3 — Markdown redundancy (N clusters)
Numbered clusters with locations + canonical + action.

## Tier 4 — Code redundancy (N items + N dead-code)
Table grouped by category.

## Tier 5 — Cosmetic (N items)
Brief list.

## Open decisions for user (N items)
Numbered, each with current state + options + recommendation.

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
