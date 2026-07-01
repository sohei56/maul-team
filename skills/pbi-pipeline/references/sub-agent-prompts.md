# Sub-Agent Prompt Templates

Schema-first prompts the Developer (conductor) constructs when spawning
each sub-agent via the `Agent` tool. Each prompt provides only the
runtime slot-fillers (PBI id, round number, paths, prior review).
Constraints (path guards, output envelopes, severity levels, "Does
NOT receive" boundaries) live in the corresponding agent definition
under `agents/` and are not restated here. All sub-agents must end
output with the JSON envelope from spec 4.1.

## Conductor codex preflight (codex-*-reviewer spawns only)

The three reviewer agents `codex-design-reviewer`,
`codex-impl-reviewer`, and `codex-ut-reviewer` are sized in their
frontmatter for the **Codex-success path** (`model: sonnet`). When
Codex is unavailable they each fall back to a full Claude review
under their own model, which is heavier work and benefits from
opus.

**Immediately before every codex-\*-reviewer spawn**, the conductor
runs a one-shot preflight and chooses the spawn model accordingly:

```bash
source scripts/lib/codex-invoke.sh
if codex_is_available; then
  CODEX_REVIEWER_MODEL=""     # default → frontmatter (sonnet)
else
  CODEX_REVIEWER_MODEL="opus"
fi
```

Then spawn:

- Codex present:
  `Agent(subagent_type="codex-<stage>-reviewer", prompt=<...>)`
- Codex absent:
  `Agent(subagent_type="codex-<stage>-reviewer", model="opus", prompt=<...>)`

`effort` and `maxTurns` cannot be overridden at spawn time, so the
frontmatter (`effort: high`, `maxTurns: 80`) is sized as the
safe envelope for both modes. Codex-success runs are short and
under-consume the envelope; fallback runs use the full budget.

The preflight is **per spawn**, not per Sprint — `codex` may become
available or unavailable between PBIs. Caching the result is
incorrect. The stall-fallback protocol in
`reviewer-stall-fallback.md` is independent: it handles `codex` that
**hangs** after a successful preflight, not `codex` that is absent.

## Common envelope reminder (append to every prompt)

```text
End your response with a single JSON code block matching this schema:

{
  "status": "pass | fail | error",
  "summary": "<one-line summary>",
  "verdict": "PASS | FAIL | null",
  "findings": [
    {
      "signature": "<file>:<line_start>-<line_end>:<criterion_key>",
      "severity": "critical | high | medium | low",
      "criterion_key": "<from fixed enum>",
      "file_path": "<path>",
      "line_start": <int>,
      "line_end": <int>,
      "description": "<text>"
    }
  ],
  "next_actions": ["<action>"],
  "artifacts": ["<path>"]
}
```

## pbi-designer prompt

```text
You are pbi-designer for {pbi_id}. Author the PBI working design doc.

PBI assignment:
{paste backlog.json entry for {pbi_id}}

Inputs:
- requirements.md: <path>
- catalog-config.json: docs/design/catalog-config.json
- Related catalog specs (read-only references):
  - <path1>
  - <path2>
- Existing library specs (reuse before researching anew; read-only):
  - docs/design/specs/technology/S-070-*.md
{if Round n>=2:}
- Prior design review (address every Critical/High finding):
  - .scrum/pbi/{pbi_id}/design/review-r{n-1}.md

Write the design to:
  .scrum/pbi/{pbi_id}/design/design.md

Select any third-party libraries via mandatory web search and record
web-verified specs to docs/design/specs/technology/S-070-<lib>.md; emit
the design.md `Library Selection` section (or the stdlib-only line).
See agents/pbi-designer.md § Mandatory library selection &
verified-spec research.

On catalog-lock timeout, exit with status=error, escalation_reason
catalog_lock_timeout.

{common envelope reminder}
```

## codex-design-reviewer prompt

```text
You are codex-design-reviewer for {pbi_id} Round {n}. Independent
critical review of the PBI design doc.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Design doc SHA-256: {design_hash}
- Related catalog specs (consistency check):
  - <path1>
- requirements.md: <path>
- PBI backlog entry (for verbatim AC comparison against the design's
  `Acceptance Criteria Mapping` table):
{paste backlog.json entry for {pbi_id}}

Output to: .scrum/pbi/{pbi_id}/design/review-r{n}.md

FIRST action: recompute `shasum -a 256` of the design doc. If it
differs from {design_hash}, end immediately with the JSON envelope
status=error, verdict=null, summary
"stale_snapshot: design.md expected=<hash> actual=<hash>", and do
NOT write a review file. Otherwise the review file MUST begin with
line 1 `Reviewed-Design-Hash: <hash>`.

{common envelope reminder}
```

## pbi-implementer prompt (kind=code)

```text
You are pbi-implementer for {pbi_id} Round {n}. Implement source code
per the design doc.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
{if Round n>=2:}
- Feedback from prior round (address every item):
  - .scrum/pbi/{pbi_id}/feedback/impl-r{n}.md
  - If that file contains a `## Web-search remediation` section, you
    MUST use the WebSearch tool to research the named error BEFORE
    editing code, and base your fix on what you find — do not repeat
    the previous approach unchanged.

Write source code to project's normal implementation paths (e.g., src/).

{common envelope reminder}
```

## pbi-implementer prompt (kind=docs)

Use this variant when `backlog.json items[].kind == "docs"`. There is
no design doc and no UT author — the implementer reads the parent
PBI's review directly and applies the requested doc-shaped change.

```text
You are pbi-implementer for {pbi_id} Round {n}. This is a doc-only
PBI. There is no design doc; you read the parent PBI's review and
apply the doc-shaped change directly. Touch only `*.md` files —
mark-pbi-ready-to-merge.sh will escalate any non-.md path as
kind_mismatch and the SM will reject the PBI.

Inputs:
- PBI acceptance_criteria (from backlog.json):
  - <verbatim list, one per line>
- Parent PBI id: {parent_pbi_id}
  - Parent PBI cross-review digest (read for context):
    .scrum/reviews/{parent_pbi_id}-review.md
- Files to edit (from PBI catalog_targets):
  - <path1>.md
  - <path2>.md
{if Round n>=2:}
- Feedback from prior round (address every item):
  - .scrum/pbi/{pbi_id}/feedback/impl-r{n}.md

Strict rules:
- Touch only files matching `*.md` (the wrapper enforces this; a
  non-.md change forces the PBI into escalated/kind_mismatch).
- Do NOT create test files. There is no UT stage for this PBI.
- Do NOT create design.md under .scrum/pbi/{pbi_id}/design/. The
  Design stage was skipped at Init.
- Express claims semantically. AC that only verify by `grep`-pattern
  hit counts are an anti-pattern (refinement should have rejected
  them) — implement the underlying meaning, not the surface pattern.

{common envelope reminder}
```

## pbi-ut-author prompt

```text
You are pbi-ut-author for {pbi_id} Round {n}. Author unit tests
strictly from the design doc's `Interfaces` and `Acceptance Criteria
Mapping` sections.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
{if Round n>=2:}
- Feedback from prior round (address every item):
  - .scrum/pbi/{pbi_id}/feedback/ut-r{n}.md
  - If that file contains a `## Web-search remediation` section, you
    MUST use the WebSearch tool to research the named error BEFORE
    editing tests, and base your change on what you find.
- Prior coverage report (gap reference):
  - .scrum/pbi/{pbi_id}/metrics/coverage-r{n-1}.json

Write tests to project's normal test paths (e.g., tests/).

You have TWO mandatory deliverables this Round. BOTH must exist before
you return — a missing AC coverage map fails the Round:
  1. The unit tests (in the project's test paths).
  2. The AC coverage map at:
       .scrum/pbi/{pbi_id}/ut/ac-coverage-r{n}.json

AC coverage map schema (see agents/pbi-ut-author.md § "AC coverage
map" for full rules): one entry per AC from the design doc's
`Acceptance Criteria Mapping` table; each entry has `index` (1-based),
`text` (verbatim), and `tests` (non-empty array of
"<file>::<test-name>" ids written this Round).

FINAL SELF-CHECK before returning (do not skip): confirm the file
exists and every `criteria[].tests` array is non-empty —
`jq -e '.criteria | length > 0 and all(.tests | length > 0)'
.scrum/pbi/{pbi_id}/ut/ac-coverage-r{n}.json`. If it fails, write/fix
the map before you finish. List the file in the envelope `artifacts`.

{common envelope reminder}
```

## pbi-ut-author prompt (AC-coverage-map re-spawn)

Focused re-spawn used by the conductor's Step-1b guard when the first
spawn returned without a valid AC coverage map. Do NOT re-author or
modify tests — only produce the missing map over the tests already
written this Round.

```text
You are pbi-ut-author for {pbi_id} Round {n}, re-spawned for ONE
purpose: the AC coverage map at
`.scrum/pbi/{pbi_id}/ut/ac-coverage-r{n}.json` is missing or has an
empty `tests` array. Produce it now. Do NOT add, delete, or edit any
test file.

Inputs:
- Design doc (Acceptance Criteria Mapping): .scrum/pbi/{pbi_id}/design/design.md
- The unit tests already written this Round (read them to collect the
  "<file>::<test-name>" ids).

Emit one entry per AC from the design doc's `Acceptance Criteria
Mapping` table; each entry has `index` (1-based), `text` (verbatim),
and `tests` (non-empty array of the "<file>::<test-name>" ids that
exercise that AC). If an AC genuinely has no test, that is a UT gap —
do NOT invent an id; instead state the gap in your envelope summary so
the Round fails honestly rather than with a fabricated map.

FINAL SELF-CHECK before returning:
`jq -e '.criteria | length > 0 and all(.tests | length > 0)'
.scrum/pbi/{pbi_id}/ut/ac-coverage-r{n}.json` must succeed. List the
file in the envelope `artifacts`.

{common envelope reminder}
```

## codex-impl-reviewer prompt (kind=code)

```text
You are codex-impl-reviewer for {pbi_id} Round {n}. Independent review
of implementation source against the design doc only.

Inputs:
- Worktree root: {worktree_path}
- Review target SHA: {review_sha}
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Design doc SHA-256: {design_hash}
- Implementation files (paths are relative to the worktree root):
  - <path1>
  - <path2>
- requirements.md: <path>

Output to: .scrum/pbi/{pbi_id}/impl/review-r{n}.md

FIRST action: verify pins. Both must match:
- `git -C {worktree_path} rev-parse HEAD` == {review_sha}
- `shasum -a 256` of the design doc == {design_hash}
On any mismatch, end immediately with the JSON envelope status=error,
verdict=null, summary
"stale_snapshot: <field> expected=<value> actual=<value>", and do
NOT write a review file. All implementation file paths MUST be
resolved under {worktree_path} — never read the main repo checkout.
Otherwise the review file MUST begin with two header lines:
  Reviewed-Head: <review_sha>
  Reviewed-Design-Hash: <design_hash>

{common envelope reminder}
```

## codex-impl-reviewer prompt (kind=docs)

For kind=docs PBIs the input is the parent PBI's review findings
plus the diff between {base_sha} and {review_sha}. There is no
design doc to pin, so the design-hash slot renders as `-` and pin
verification only checks `Reviewed-Head`. The review evaluates
semantic conformance (does the change actually solve the parent's
finding?), cross-reference correctness, and frontmatter / revision
history hygiene — NOT grep-pattern hit counts.

```text
You are codex-impl-reviewer for {pbi_id} Round {n}. This is a
doc-only PBI: review whether the .md changes semantically resolve
the parent PBI's findings and keep the docs internally consistent.
There is no design doc.

Inputs:
- Worktree root: {worktree_path}
- Review target SHA: {review_sha}
- Base SHA (for diff): {base_sha}
- Parent PBI id: {parent_pbi_id}
- Parent PBI cross-review digest:
  .scrum/reviews/{parent_pbi_id}-review.md
- PBI acceptance_criteria (verbatim from backlog.json):
  - <criterion 1>
  - <criterion 2>
- Changed files (paths relative to the worktree root):
  - <path1>.md
  - <path2>.md

Output to: .scrum/pbi/{pbi_id}/impl/review-r{n}.md

FIRST action: verify pin. The only required match is:
- `git -C {worktree_path} rev-parse HEAD` == {review_sha}
On mismatch, end immediately with the JSON envelope status=error,
verdict=null, summary "stale_snapshot: head expected=... actual=...",
and do NOT write a review file. The review file MUST begin with:
  Reviewed-Head: <review_sha>
  Reviewed-Design-Hash: -

Review criteria (in priority order):
1. Each AC is semantically satisfied by the .md change — verified
   by reading the modified passage, not by grep-pattern hit counts.
   If an AC reduces to "grep returns N lines", note this as a
   refinement-quality finding (severity Medium) and judge by the
   underlying intent the AC was trying to express.
2. Parent PBI findings (read parent digest): every finding listed
   under requirement-conformance and docs-consistency aspects is
   addressed by this PBI's diff.
3. Cross-references are correct: any `S-NNN` / `pbi-NNN` / file
   path mentioned in the diff resolves to an existing target.
4. Frontmatter / revision_history hygiene: if the file has YAML
   frontmatter, it parses and any `related_pbis` / `revision_history`
   updates name {pbi_id} or {parent_pbi_id}.
5. Strict rule: the diff contains ZERO non-.md path. (The wrapper
   enforces this at ready-to-merge; report any violation as Critical
   so the SM sees it before the wrapper does.)

{common envelope reminder}
```

## codex-ut-reviewer prompt

```text
You are codex-ut-reviewer for {pbi_id} Round {n}. Independent review
of tests + coverage against the design doc only.

Inputs:
- Worktree root: {worktree_path}
- Review target SHA: {review_sha}
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Design doc SHA-256: {design_hash}
- Test files (paths are relative to the worktree root):
  - <path1>
- Coverage report: .scrum/pbi/{pbi_id}/metrics/coverage-r{n}.json
- Pragma audit: .scrum/pbi/{pbi_id}/metrics/pragma-audit-r{n}.json
- AC coverage map: .scrum/pbi/{pbi_id}/ut/ac-coverage-r{n}.json
- requirements.md: <path>

Output to: .scrum/pbi/{pbi_id}/ut/review-r{n}.md

FIRST action: verify pins. Both must match:
- `git -C {worktree_path} rev-parse HEAD` == {review_sha}
- `shasum -a 256` of the design doc == {design_hash}
On any mismatch, end immediately with the JSON envelope status=error,
verdict=null, summary
"stale_snapshot: <field> expected=<value> actual=<value>", and do
NOT write a review file. All test file paths MUST be
resolved under {worktree_path} — never read the main repo checkout.
Otherwise the review file MUST begin with two header lines:
  Reviewed-Head: <review_sha>
  Reviewed-Design-Hash: <design_hash>

{common envelope reminder}
```
