---
name: backlog-refinement
description: Refine coarse-grained PBIs into implementation-ready items
disable-model-invocation: false
---

## Inputs

- `backlog.json` → items with status: draft
- `requirements.md`
- Count of existing refined PBIs (WIP check)

## Outputs

- `backlog.json` → items[].status: refined, acceptance_criteria (non-empty), ux_change, design_doc_paths, priority (non-negative integer)

## Preconditions

- state.json phase: "backlog_created" or "retrospective"
- backlog.json has ≥1 draft PBI
- Refined PBI count < WIP cap 12

## Steps

1. Read backlog.json
2. Count refined PBIs. If ≥12→skip (WIP cap reached)
3. Each draft PBI (up to WIP cap 12 total refined):
   a. Break into implementation-ready items (per function/screen/API/component)
   b. Fill `acceptance_criteria` (Definition of Ready). Every string MUST
      be **independently verifiable** — either:
      - Given/When/Then form, or
      - a measurable assertion: observable input/action → expected
        observable outcome. Numeric thresholds are numbers, not adjectives.

      Reject vague adjectives without a measurable condition: "robust",
      "intuitive", "fast", "user-friendly", "error handling is robust",
      "good performance". Rewrite as a concrete check, or split into
      multiple criteria that each name an observable check.

      **AC array order is significant.** The 1-based index of each
      string is the AC's id used by downstream artifacts: the design
      doc's `Acceptance Criteria Mapping` section and the UT
      `ac-coverage-r{n}.json` map both reference it by index. Do not
      reorder a PBI's `acceptance_criteria` after refinement without
      a Change Process update — downstream references go stale.
   c. Set ux_change (user-facing changes)
   d. Set design_doc_paths (docs needing creation/update)
   e. Assign priority (non-negative integer, lower = higher priority, 1 = highest) via wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" priority <integer>
      ```
      **Integer only.** String labels (`"high"`/`"medium"`/`"low"`) violate the
      schema and break the dashboard PBI Board. The wrapper rejects non-integers.
4. Set status→"refined"
5. Write backlog.json
6. Report: count refined, total refined WIP

Ref: FR-003

## Exit Criteria

- All selected PBIs status: refined
- Every refined PBI: non-empty acceptance_criteria, ux_change set, design_doc_paths set, priority set (integer)
- Every `acceptance_criteria[i]` is independently verifiable per Step 3b
  (Given/When/Then or measurable assertion; no bare vague adjective)
- Total refined PBIs within 6-12 range
