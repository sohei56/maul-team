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

      **Opus override for AC verifiability + scenario coverage
      (mandatory).** AC quality failures recurred 5 times across 3
      projects (kaiten_bot `IMP-007`, `IMP-018`, `IMP-019`;
      stock_bo_monitoring `IMP-S010-004`; cars_auction_ui `imp-010`). Each failure traces to AC that pass the surface
      check above (Given/When/Then or measurable assertion) but miss
      one of: (i) scenario coverage (normal / failure / edge), (ii)
      mandatory grep-zero on deleted config variables, (iii) parity
      with a reference implementation when one exists. The SM main
      loop runs on Sonnet; pinning these rules in skill text has not
      been sufficient. Delegate the per-AC verifiability + coverage
      audit to an Opus-backed sub-agent via the `Agent` tool, on each
      PBI's draft AC list, before setting `status: refined`:

      ```
      Agent({
        subagent_type: "general-purpose",
        model: "opus",
        description: "AC verifiability audit",
        prompt: <<<EOF
          Audit the acceptance_criteria of one PBI before refinement.

          Inputs:
          - PBI id, title, description, ux_change
          - Draft acceptance_criteria (string array)
          - PBI type signal: derive from description keywords
            (impl / refactor / config-removal / order-engine /
             schema-version / docs-only / audit-follow-up)

          Checks per AC string:
          1. Verifiability: Given/When/Then form OR observable
             input/action -> observable outcome. Reject vague
             adjectives without a measurable condition.
          2. Scenario coverage across the AC array as a whole:
             (a) normal-path AC present
             (b) failure-mode AC present (when impl PBI)
             (c) edge-case AC present (concurrency / null / boundary)
          3. Type-specific mandatory clauses:
             - config-removal PBI -> "grep <removed-symbol> returns
               zero across docs/ and CLAUDE.md" must appear
             - SCHEMA_VERSION bump PBI -> "requirements.md and the
               schema doc reflect the new version" must appear
             - order-engine PBI -> "price parity with backtest
               reference implementation" must appear (kaiten_bot
               IMP-019)
             - audit-follow-up PBI -> UT scenarios named explicitly
               per AC (stock_bo_monitoring IMP-S010-004)
          4. AC ordering: normal-path first, failure / edge after.

          Output: JSON
            {
              "verdict": "pass" | "needs_revision",
              "per_ac": [
                { "index": 1, "text": "...", "issues": ["..."],
                  "rewrite_suggestion": "..." | null }
              ],
              "missing_acs": [ "<concrete AC to add>" ]
            }
        EOF
      })
      ```

      SM main loop reads the JSON. If `verdict == "needs_revision"`,
      apply `rewrite_suggestion` for flagged AC and append every
      `missing_acs` entry before persisting. Do not advance status to
      `refined` until the next audit returns `verdict: pass`.
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
