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
      target projects. Each failure traces to AC that pass the surface
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
        description: "AC verifiability + kind audit",
        prompt: <<<EOF
          Audit the acceptance_criteria of one PBI before refinement,
          AND classify it as kind=code or kind=docs.

          Inputs:
          - PBI id, title, description, ux_change
          - Draft acceptance_criteria (string array)
          - catalog_targets (string array; may be empty)
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
               reference implementation" must appear
             - audit-follow-up PBI -> UT scenarios named explicitly
               per AC
          4. AC ordering: normal-path first, failure / edge after.

          Kind classification (3-axis OR rule, lean toward `code` on
          ambiguity — false-negative `code` is harmless, false-positive
          `docs` skips UT/coverage gates and lets code slip through):

          - Axis A — description markers: "doc-only", "docs-consistency",
            "documentation only", "[docs]", "[doc]" anywhere in title or
            description.
          - Axis B — AC content: every AC describes a doc-shaped change
            (a passage exists / a cross-reference is correct /
            frontmatter / revision_history / spec text). NO AC names a
            runtime behaviour, API contract, UI interaction, or DB
            mutation.
          - Axis C — catalog_targets non-empty AND all elements end in
            `.md`.

          Decision: kind = "docs" iff (A AND B), OR (B AND C). All other
          cases → kind = "code". (Axis A alone is a marker but not
          sufficient — title text can lie. Axis C alone happens when a
          code PBI also updates a spec — still code.)

          Extra Check 5 — grep-shaped AC anti-pattern (applies when
          kind == "docs"):
          - Reject any AC whose verifiable claim is reducible to
            "grep <pattern> in <file> returns N lines" / "<file>
            contains <substring>" / "occurrence count == N" without a
            semantic read of the content.
          - Replace with: "<file> §X states <semantic claim>, verified
            by reviewer reading the passage". The cross-review's
            requirement-conformance reviewer reads passages; grep is
            not a substitute for comprehension.
          - Rationale: target-project pbi-054 had 6 grep-shaped AC and
            the UT author wrapped each grep in a test function. The
            tests passed without anyone (human or model) reading the
            doc. Never again.

          Output: JSON
            {
              "verdict": "pass" | "needs_revision",
              "kind": "code" | "docs",
              "kind_rationale": "axes A=<true|false> B=<...> C=<...>; decision=...",
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

      Persist `kind` on every PBI (code or docs — never leave the
      field unset, the default is for legacy data only):
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" kind <code|docs>
      ```

      Persist the audited AC list via the wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" \
        acceptance_criteria '["AC 1 ...","AC 2 ..."]'
      ```
      The wrapper validates JSON-array-of-strings; status remains
      `draft` until step 4 below.
   c. Set ux_change (user-facing changes) via wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" ux_change <true|false>
      ```
   d. Set design_doc_paths (docs needing creation/update) via wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" \
        design_doc_paths '["docs/design/specs/feature-x.md","docs/design/specs/feature-y.md"]'
      ```
   e. (Optional) Set description / depends_on_pbi_ids via wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" description "..."
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" \
        depends_on_pbi_ids '["pbi-001","pbi-002"]'
      ```
   f. Assign priority (non-negative integer, lower = higher priority, 1 = highest) via wrapper:
      ```bash
      .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" priority <integer>
      ```
      **Integer only.** String labels (`"high"`/`"medium"`/`"low"`) violate the
      schema and break the dashboard PBI Board. The wrapper rejects non-integers.

   All field writes above MUST go through
   `.scrum/scripts/set-backlog-item-field.sh`. The PreToolUse guard
   blocks raw edits to `.scrum/backlog.json`; status is the only field
   with its own wrapper (`update-backlog-status.sh`).
4. Flip status→"refined" via wrapper:
   ```bash
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" refined
   ```
5. Report: count refined, total refined WIP

Ref: FR-003

## Exit Criteria

- All selected PBIs status: refined
- Every refined PBI: non-empty acceptance_criteria, ux_change set, design_doc_paths set, priority set (integer), kind set (`code` or `docs`)
- Every `acceptance_criteria[i]` is independently verifiable per Step 3b
  (Given/When/Then or measurable assertion; no bare vague adjective)
- For kind=docs PBIs: no AC reduces to a grep-pattern hit count (see Check 5 above)
- Total refined PBIs within 6-12 range
