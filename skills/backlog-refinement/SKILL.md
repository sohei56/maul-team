---
name: backlog-refinement
description: Refine coarse-grained PBIs into implementation-ready items
disable-model-invocation: false
---

## Inputs

- `backlog.json` → items with status: draft
- `requirements.md`
- `docs/requirements-benchmark.md` — prior-art / similar-case findings
  with per-item dispositions produced by Requirement Definition (reuse
  first before any refinement-time web search; may be absent on a
  pre-brief / resumed project)
- Count of existing refined PBIs (WIP check)

## Outputs

- `backlog.json` → items[].status: refined, acceptance_criteria (non-empty), ux_change, design_doc_paths, priority (non-negative integer)
- Every refined PBI carries a **settled approach/method** — the
  solution direction is recorded in `description` (and the doc it will
  shape is named in `design_doc_paths`), with no PO-only spec question
  about it left open (see Steps 3.a2 / 3.a3)
- `.scrum/po/decisions.json` (agent mode) — any `spec_clarification`
  ruling emitted during refinement, logged via `append-po-decision.sh`

## Preconditions

- state.json phase: "backlog_created" or "retrospective"
- backlog.json has ≥1 draft PBI
- Refined PBI count < WIP cap 12

## PO seat resolution (po_mode)

The PO-clarification points below (Step 3.a3, and any PO-only spec
question surfaced during 3.a2 research) resolve to the PO seat per
`.scrum/config.json.po_mode` and `rules/scrum-context.md` § PO seat
resolution:

- `human` (default) → the SM asks the user in the main session and
  waits for a natural-language reply.
- `agent` → the SM routes
  `[<pbi-id>] PO_DECISION_REQUEST kind=spec_clarification options=[...]
  recommendation=<...>` to the `product-owner` teammate and proceeds on
  the returned `PO_DECISION` (logged via `append-po-decision.sh`, with
  the `dec_id` echoed). **Never block on human input**: a genuinely
  human-only unknown is appended to `.scrum/po/attention.md` and the
  PBI stays `draft`.

The route is invariant across modes; only the seat changes. SM remains
the sole broker — sub-agents never address the PO directly.

## Steps

1. Read backlog.json
2. Count refined PBIs. If ≥12→skip (WIP cap reached)
3. Each draft PBI (up to WIP cap 12 total refined):
   a. Break into implementation-ready items (per function/screen/API/component)

   a2. **Approach & prior-art clarity gate (mandatory, before AC).**
      The goal of refinement is to hand the Developer a PBI whose
      **solution approach/method is settled** — not one where the
      designer must guess the method or reverse-engineer intent. Before
      writing AC, decide per item whether the approach is determinable
      from `requirements.md` + `docs/requirements-benchmark.md`:
      - **Reuse `docs/requirements-benchmark.md` first.** It already
        holds prior-art dispositions (`adopt`/`adapt`/`reject`) from
        Requirement Definition. Do NOT re-search what it already
        answers.
      - Is there a known prior-art / similar-case pattern for this
        feature, and is the technical direction (algorithm / protocol /
        data model / integration style) determinable, or genuinely
        open?

      If a gap remains that a targeted search can close (prior-art or
      tech-direction **not** settled at Requirement Definition),
      delegate a **bounded web search** to an Opus sub-agent (mirrors
      the Requirement Definition benchmark pattern). Record the resolved
      direction into the PBI `description`, and name the doc it will
      shape in `design_doc_paths` (step 3d):

      ```
      Agent({
        subagent_type: "general-purpose",
        model: "opus",
        description: "Refinement approach/prior-art research",
        prompt: <<<EOF
          Given one PBI (title, description, draft AC) plus excerpts of
          requirements.md and requirements-benchmark.md, close the
          *approach/method* gap for this PBI.

          Rules:
          1. Reuse requirements-benchmark.md first; only search for what
             it does NOT already answer.
          2. Run >=3 distinct WebSearch queries on prior art / similar
             solutions / the accepted method for this feature, then
             WebFetch the most relevant sources. Ground every claim in a
             source read this session — never from memory.
          3. Return the settled approach, the sources, the design docs
             it should shape, and any residual question that ONLY the PO
             can answer (business rule / scope boundary / ordering /
             threshold / acceptance semantics).

          Scope boundary — do NOT duplicate the Design stage. Detailed
          per-library API selection and the S-070 technology specs are
          the pbi-designer's mandatory library web search at Design
          time. Here, settle *direction/method* only; do not pre-empt
          library-level choices.

          Output JSON:
            {
              "approach": "<settled method, 1-3 sentences>",
              "sources": ["<url>", ...],
              "shapes_docs": ["docs/design/specs/....md", ...],
              "po_questions": ["<spec question only the PO can answer>", ...]
            }
          If WebSearch is unavailable or fails at the harness level (not
          a "no results" content outcome), return
            {"harness_incident": "websearch_unavailable"}
          and do NOT fabricate an approach from memory.
        EOF
      })
      ```

      SM main loop reads the JSON: fold `approach` into the PBI
      `description`, merge `shapes_docs` into `design_doc_paths`, and
      carry every `po_questions` entry into step 3.a3. On
      `harness_incident` treat it as a **harness incident, not a
      fallback** (mirrors requirement-definition step 5): surface per
      the PO seat (human → tell the user and wait; agent → append to
      `.scrum/po/attention.md`) and do not fabricate an approach.

      **Boundary restated:** this step settles approach/method
      *direction* only. Per-library API selection + `S-070` specs stay
      with the Design stage — do not duplicate them here.

   a3. **PO clarification for residual spec ambiguity (do not pass
      ambiguity downstream).** After research, resolve **now** — not by
      deferring to the Developer/designer — any remaining unknown that
      is **PO-only**: a business rule, scope boundary, ordering /
      threshold, or acceptance semantics. Apply the escalate-vs-guess
      filter in `rules/scrum-context.md` § When you don't know:
      - Escalate (route to the PO seat) when guessing wrong would change
        observable behavior or break a contract. See § PO seat
        resolution above for the human / agent routing; fold the
        answer/ruling into the PBI `description` / AC before refining.
      - Do **not** escalate purely reversible unknowns (local naming,
        internal decomposition, test-fixture values) — leave those to
        the pipeline. Over-escalation defeats the point.

      **Never guess PO intent.** An item is not eligible for `refined`
      while a PO-only question about it is open (human mode: unanswered;
      agent mode: no matching `PO_DECISION` / parked in `attention.md`).

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
      `refined` until the next audit returns `verdict: pass`. If an AC
      cannot be made verifiable without a PO-only decision (e.g. an
      undecided acceptance threshold), route that question through step
      3.a3 rather than inventing a value.

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

   **Superseded drafts → `cancelled`.** If refinement absorbed a draft
   PBI into another PBI, replaced it with child PBIs (its scope is
   fully covered by items carrying `parent_pbi_id`), or the PO ruled
   it no longer needed, do not leave it lingering as `draft` (and
   never park it as `blocked` — that status is hold-and-resume only):
   ```bash
   .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" \
     description "Superseded by <pbi-ids / reason>. <original description>"
   .scrum/scripts/update-backlog-status.sh "$PBI_ID" cancelled
   ```
   `cancelled` is terminal; record the superseding pbi-ids in the
   description first so the audit trail survives.
5. Report: count refined, total refined WIP, count cancelled (superseded)

Ref: FR-003

## Exit Criteria

- All selected PBIs status: refined
- Every refined PBI: non-empty acceptance_criteria, ux_change set, design_doc_paths set, priority set (integer), kind set (`code` or `docs`)
- Every `acceptance_criteria[i]` is independently verifiable per Step 3b
  (Given/When/Then or measurable assertion; no bare vague adjective)
- For kind=docs PBIs: no AC reduces to a grep-pattern hit count (see Check 5 above)
- Every refined PBI has a **settled approach/method** recorded in
  `description` (Step 3.a2) — the designer is not left to guess the
  method; approach/prior-art gaps were closed by reusing
  `requirements-benchmark.md`, by delegated web research, or by a PO
  `spec_clarification` decision
- **No PO-only spec question about a refined PBI is left open** (Step
  3.a3) — human mode: answered; agent mode: a matching `PO_DECISION` is
  logged, or the question is parked in `.scrum/po/attention.md` and the
  PBI remains `draft`
- Any WebSearch harness incident encountered during 3.a2 was surfaced
  (not papered over with fabricated approach)
- Total refined PBIs within 6-12 range
