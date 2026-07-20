---
name: codebase-audit
description: >
  Whole-repo, multi-agent audit that IS the Sprint-end cross-review
  ceremony (product-wide integrity): 4 axes — spec-conformance,
  logic/defect hunt, redundancy, and product-security — over the
  ACCUMULATED codebase at HEAD, not the Sprint diff. Findings are
  swept to zero per defect class — one class = one PBI covering every
  occurrence, documentation drift batched into a single DOCS PBI — and
  non-blocking: Critical/High become draft PBIs for the NEXT Sprint,
  Medium/Low at PO discretion. At Integration-Sprint entry a thin
  re-check confirms the latest audit is fresh and no open Critical/High
  audit PBIs remain before testing proceeds.
disable-model-invocation: false
---

## Role

Per-PBI review — the codex reviewers and the 5-aspect Integrity stage
— sees one PBI's diff. A diff-scoped gate cannot see defects that only
emerge in the **accumulated whole**: dead code that is also an
unimplemented requirement, an I/O default that silently disables a
feature, a silent failure in the wiring layer, two design specs
mandating contradictory behavior, or the same logic implemented twice
across PBIs from different Sprints. Those defects survive every
diff-scoped gate.

This skill closes that gap with a **whole-repo audit at HEAD**, run in
two contexts. It is SM-owned and read-only: auditors read and reason,
they never edit.

| Context | When | Gate semantics |
|---|---|---|
| **(a) cross-review** (primary) | Every Sprint, embedded in the `cross-review` ceremony | **Non-blocking.** Never fails the Sprint, never transitions the phase. Critical/High → mandatory draft PBIs for the **next** Sprint; Medium/Low at PO discretion. |
| **(b) integration entry** (thin re-check) | Once, at the top of `integration-tests` Step 1 | Verifies the latest audit is **fresh** and no open Critical/High audit PBI remains. Both hold → proceed. Stale/missing → run a fresh audit; unresolved Critical/High → **block** and route to `backlog_created`. |

Context (a) is the audit's real home — findings are caught every Sprint
and fixed in the normal development cadence, so the Integration Sprint
starts from an already-audited, already-remediated codebase. Context
(b) is a cheap safety re-check, not a fresh full audit in the common
case: it exists only to close the hole where an audit PBI was filed but
never fixed before integration.

The audit runs along four evidence-based axes, each a single parallel
auditor via the `Agent` tool:

| Axis | Focus | What only this axis catches |
|---|---|---|
| `spec-conformance` | Implementation vs enabled specs + requirements | Divergences, coded-but-unspecified behavior (dead code that is also a spec gap), and spec-vs-spec conflicts |
| `logic-defect` | I/O orchestration + wiring layer | Feature-disabling production defaults, boundaries unit tests mock out, silent failures, edge cases in scheduling / state transitions |
| `redundancy` | Dead code, cross-PBI duplication, stale docs | Unused exports, duplicate implementations of the same logic across PBIs, docstrings that no longer match the code |
| `product-security` | Product-wide security integrity | Authorization boundaries spanning components/PBIs, data flows crossing trust boundaries, secrets/credential handling across the codebase, injection surfaces at integration points, security controls no single PBI owned |

The per-PBI pipeline now runs a diff-local security aspect review on
each PBI before it reaches `awaiting_cross_review`. The audit's
`product-security` axis is deliberately the **complement** of that: it
owns only what a single-PBI diff cannot see (cross-component authz,
whole-repo secret handling, integration-point injection surfaces), and
does **not** re-review single-PBI diff-local security.

## Inputs

- **`context`** — `cross_review` (default; embedded in the
  `cross-review` ceremony) or `integration_entry` (the thin re-check).
  Determines the gate semantics and whether the axes actually run.
- `.scrum/state.json` — current phase.
- `.scrum/sprint.json` — `id` (drives the report filename) and
  `base_sha` (context only; the audit scope is HEAD, **not** a diff).
- `.scrum/backlog.json` — all PBIs (`id`, `title`,
  `acceptance_criteria`, `kind`, `status`, `description`) — for the
  spec-conformance axis to map requirements to implementation, for
  cross-PBI duplication reasoning, and for **cross-Sprint PBI dedup**
  (existing `[codebase-audit:*]` items).
- `docs/requirements.md` — the requirement SSOT.
- `docs/design/catalog-config.json` — the `enabled` array of spec IDs.
- `docs/design/specs/**` — enabled spec files (per
  `docs/design/catalog.md`, each at
  `docs/design/specs/{category}/{id}-{slug}.md`).
- `.scrum/po/decisions.json` — the PO decision log. The
  spec-conformance axis checks it for an adjudication **before**
  flagging a spec-vs-spec conflict (an already-decided conflict is not
  a finding).
- `.scrum/reviews/static-analysis-r*.json` — most recent
  `cross-review` static-analysis output. In context (a) this is
  produced by the same cross-review round (its two-pass scan feeds the
  redundancy axis as ground truth); absent, the axis falls back to
  reachability reasoning at explicitly lower confidence.
- Project source code + test suites (whole repo at HEAD).

## Outputs

- `.scrum/reviews/codebase-audit-s{N}.md` — the synthesized audit
  report (`N` = numeric sprint number from `sprint.json.id`, e.g.
  `codebase-audit-s3.md` for `sprint-003`). Deduped findings, each with
  axis, severity, `file:line`, identity key, evidence, and
  fact-vs-interpretation separated.
- Draft PBIs in `.scrum/backlog.json` via
  `.scrum/scripts/add-backlog-item.sh`, title prefix
  `[codebase-audit:<sprint-id>:F<n>:<Severity>]` (severity in the
  prefix so context (b)'s block-check is prefix-searchable; a
  `[REGRESSION]` tag is added when a previously-closed finding recurs).
  Filing granularity is **class-level, not occurrence-level**: one PBI
  per defect class covering every occurrence the sweep found (Step 3),
  plus at most one `[codebase-audit:<sprint-id>:DOCS:<Severity>]` batch
  PBI holding ALL documentation-drift findings of the audit.
  Critical/High classes are mandatory, Medium/Low at PO discretion.
  Created as `draft` → picked up by next Sprint's
  Backlog Refinement / Sprint Planning. **Non-blocking in context (a).**
- **Context (b) only, on an unresolved Critical/High:** `state.json`
  phase → `backlog_created` via `.scrum/scripts/update-state-phase.sh`.
- A report to the user / PO (severity counts + PBIs created / skipped
  by dedup + regressions).

## Preconditions

- ≥1 Development Sprint has completed (there is accumulated code to
  audit). The audit is a no-op on an empty repo.
- `requirements.md` and the enabled design specs exist.
- Context (a): invoked inside the `cross-review` ceremony (see
  `../cross-review/SKILL.md` Steps 6–7). Context (b): invoked at
  the top of `integration-tests` Step 1.

## PO Mode (po_mode: "agent")

Under `po_mode=agent`, every "ask the user" / "PO decides" phrase
below resolves to a `PO_DECISION_REQUEST` / `PO_DECISION` exchange
with the `product-owner` teammate, per the uniform rule in
`../../rules/scrum-context.md` § PO seat resolution (flow unchanged; never
block on human input). Skill-specific overrides:

| Context | Override (po_mode=agent) |
|------|--------------------------|
| (a) cross-review | Replace the PBI-routing prompt with `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[next_sprint,defer,reject] recommendation=next_sprint` carrying the full Critical/High + Medium/Low finding list. The PO returns a route per finding in one reply; `next_sprint` → file the draft PBI, `defer`/`reject` → do not file (Critical/High default to `next_sprint`). No human-input wait, non-blocking either way. |
| (b) integration entry | On an unresolved Critical/High, replace "inform the user of the block" with `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[fix_now,defer] recommendation=fix_now` carrying the blocking PBI list. The route to `backlog_created` is taken regardless (Critical/High blocks integration); the PO reply sets fix priority, it does not waive the block. |

## Steps

### Step 0 — Resolve scope + context

```bash
SPRINT_ID="$(jq -r '.id' .scrum/sprint.json)"     # e.g. sprint-003
N="$((10#${SPRINT_ID#sprint-}))"                    # 3
REPORT=".scrum/reviews/codebase-audit-s${N}.md"
mkdir -p .scrum/reviews
```

Branch on `context`:

- **`integration_entry`** → do the **thin re-check first** (Step 1b).
  It short-circuits to *proceed* in the common case and only falls
  through to the full audit (Steps 1–5) when the report is stale/missing.
- **`cross_review`** → skip Step 1b and run Steps 1–5 (invoked from
  the `cross-review` ceremony, Steps 6–7, after it produced the
  static-analysis file).

### Step 1b — Integration-entry thin re-check (context (b) only)

```bash
FRESH_REPORT=".scrum/reviews/codebase-audit-s${N}.md"
# open audit PBIs whose severity-tagged prefix is Critical/High
# (done = fixed, cancelled = explicitly descoped by PO — neither is open)
OPEN_CH="$(jq '[.items[]
  | select(.title | startswith("[codebase-audit:"))
  | select(.title | test(":(Critical|High)\\]"))
  | select(.status != "done" and .status != "cancelled")] | length' .scrum/backlog.json)"
```

- **Fresh report exists AND `OPEN_CH == 0`** → **proceed**. Report
  "audit fresh (s${N}), no open Critical/High audit PBIs" and hand back
  to `integration-tests`. Do not run the axes.
- **Report stale / missing** (`$FRESH_REPORT` absent) → run a **fresh
  audit now**: continue into Steps 1–5 with `context=integration_entry`
  (Step 5 files PBIs with cross-Sprint dedup), then re-evaluate
  `OPEN_CH` and apply the block rule below.
- **`OPEN_CH > 0`** (audit PBIs filed in an earlier Sprint but not yet
  `done`) → **block**: route to the defect-fix loop
  (`.scrum/scripts/update-state-phase.sh backlog_created`), report the
  blocking PBI ids, and stop. This is the hole the re-check closes —
  audit PBIs that were filed but never fixed before integration.

`N` is the current sprint number, so a fresh Integration-Sprint re-entry
after a defect-fix loop (new sprint number) has no matching
`$FRESH_REPORT` and runs a fresh audit against the fixed code — intended.

### Step 1 — Assemble the shared read set

Collect for the auditors: enabled spec IDs + files, `requirements.md`,
the PBI summary (`id`, `title`, `acceptance_criteria`, `kind`), and the
most recent static-analysis file:
```bash
STATIC="$(ls .scrum/reviews/static-analysis-r*.json 2>/dev/null | sort -V | tail -1)"
```
Do NOT pass `.scrum/` pipeline state, dev communications, or PBI
descriptions beyond the fields above.

### Step 2 — Announce, spawn the 4 auditors, wait (canonical procedure)

This step is the **single owner** of the announce / spawn / wait /
clean-check procedure for the audit barrage, in every context. The
`cross-review` ceremony invokes it as "run codebase-audit § Step 2
with `context=cross_review`"; context (b) reaches it only when Step 1b
falls through to a fresh audit; a standalone invocation runs it as-is.

- **Announce expected duration (mandatory).** Before spawning, output
  one short notice so the user does not interpret silence or
  `completion-gate.sh` Stop-blocks as failure and `/clear` the session
  mid-audit (target-project retrospectives showed this UX failure 5
  Sprints in a row before the announcement convention was made
  explicit). Use this exact template, with `<label>` = `Cross-review`
  in context (a) and `Codebase audit` in context (b) / standalone:

  > "<label>: コードベース監査 4 軸を並列起動します（リポジトリ全体
  > 走査）。完了まで 60-120 秒（最大 5 分）。その間
  > `completion-gate.sh` がセッション終了をブロックします。もし 5 分
  > 以上応答がなければここに声をかけてください。"

- **Spawn the 4 axes in parallel** via the `Agent` tool — one `Agent`
  call per axis (`spec-conformance`, `logic-defect`, `redundancy`,
  `product-security`), `run_in_background: true`, single message. Each
  carries the common protocol + its axis prompt from
  [`references/axes.md`](references/axes.md) + the Step 1 read set
  (the static-analysis file is the `redundancy` axis's ground truth).
  The axes are **whole-repo** — no kind partition, no per-PBI fan-out;
  all 4 always run, even on a docs-only Sprint.
- **File ownership.** Auditors are read-only and return their findings
  **as their final assistant message**; the orchestrator synthesizes
  them in Step 3. Do NOT ask an axis to write any file — tell each
  explicitly: "Return your findings as your final message; the
  orchestrator persists the report."
- **Wait barrier.** After spawning, wait for **all 4** Tasks to reach
  `Status = completed`. Do NOT attempt to stop the session in between;
  a Stop-hook block (`completion-gate.sh` "PBIs not done") during the
  wait is not a failure. Synthesis is Step 3's job, after
  `Status = completed` — do NOT wait for the report file to appear.
  See `../../agents/scrum-master.md` § Background Subagent + Stop Hook
  Reading.
- **Axes are single-shot.** `Status = completed` is the success signal
  — do NOT apply the Teammate Liveness Protocol re-spawn rule meant
  for Developer teammates. Re-spawn only a single axis whose final
  message is missing or empty. After each completes, `git status` must
  be clean (read-only is prompt-enforced) — discard any edits and
  re-run that axis if dirty.

### Step 3 — Synthesize + dedup + classify → report

Produce the report at `$REPORT` (persist via a Bash heredoc —
`.scrum/reviews/` is carved out of the scrum-state guard; the SM has no
`Write` tool):
- **Within-audit dedup:** the same defect surfaced by two axes counts
  **once** (keep the higher severity, note both axes). A cross-boundary
  defect commonly lands on two axes — e.g. a missing authz check that is
  also a spec divergence (`product-security` + `spec-conformance`), or a
  duplicated helper that has already drifted (`redundancy` +
  `logic-defect`). Merge, keep the higher severity, note both axes.
- **Class-level merge (sweep to zero).** Findings that are instances of
  the same defect class — the same rule violated, the same guard
  missing, the same drift pattern, at different sites — merge into ONE
  class finding that enumerates **every** occurrence (`file:line` each)
  and records the sweep that establishes the list is complete (auditors
  return both per `references/axes.md`). Severity = the
  highest-severity occurrence. If an axis reported a single instance of
  a pattern that plausibly recurs but returned no sweep, re-ask that
  axis for the repo-wide sweep before synthesizing — a class filed from
  an incomplete occurrence list resurfaces as a "new" finding next
  Sprint, one site at a time, which is exactly the churn this rule
  exists to prevent.
- **Documentation-drift batch.** Every finding whose entire fix is
  documentation (stale docstrings/comments, `*.md`/spec-text drift —
  typically the redundancy axis's stale-docs class) collapses into one
  synthetic `DOCS` finding listing all occurrences, severity = highest
  member. Documentation drift is never filed as individual PBIs — the
  per-occurrence PBI spread measurably drags Sprint velocity without
  adding safety.
- **Redundancy axis is static-analysis-grounded.** In context (a) the
  `redundancy` axis consumes the same two-pass static-analysis file
  cross-review produced (Pass A Sprint-diff lint + Pass B whole-repo
  reachability). Sprint-end review no longer has a separate
  maintainability aspect — the `redundancy` axis is the sole Sprint-level
  owner of whole-repo dead-code findings, so it must cite that file as
  ground truth (absent → reachability reasoning at lower confidence).
- **Severity** (table below) per distinct finding.
- Number findings `F1..Fn`; each carries axis(es), severity,
  `file:line`, `identity` key, fact, interpretation (labeled
  separately), and a one-line proposed fix / AC.
- Report structure: headline (total findings, Critical/High count) →
  severity-sorted finding table → per-finding detail → the derived /
  skipped / regression PBI list.

**Severity definitions:**
| Severity | Definition |
|---|---|
| **Critical** | Breaks a core acceptance criterion, corrupts or silently drops data on a production path, or a spec-vs-spec conflict that makes correct behavior undefined. |
| **High** | Feature-disabling production default, unhandled failure on a primary path, a spec divergence that changes observable behavior, or a cross-PBI duplicate implementation that will drift out of sync. |
| **Medium** | Dead code / unused export, an edge-case gap on a secondary path, or a stale docstring/comment that actively misleads. |
| **Low** | Cosmetic redundancy or comment drift with no behavioral or maintenance risk. |

### Step 4 — Route findings (PO)

- **Critical/High** → mandatory: route to the next Sprint as draft
  PBIs (Step 5). In `po_mode=agent`, this is one `defect_triage`
  request (PO Mode table); Critical/High default to `next_sprint`.
- **Medium/Low** → at PO discretion. Offer them in the same request;
  file only those the PO routes to `next_sprint`.

Context (a) is **non-blocking regardless of severity** (per § Role) —
do not transition the phase, do not fail the Sprint, never revert a
PBI; the audit only files next-Sprint PBIs.

### Step 5 — File PBIs with cross-Sprint content dedup

For each **class finding** the PO routed to `next_sprint`, file ONE
draft PBI covering all of its occurrences (the `DOCS` batch files the
same way, as a single PBI) — but the audit runs **every** Sprint, so an
unfixed finding re-detected next Sprint must NOT spawn a duplicate.
Dedup is **content-based on the `identity` key** (the defect-class key
from the finding), not on the (per-Sprint) prefix:

```bash
# IDENTITY, Fn, SEVERITY, SUMMARY, AC, KIND from the finding
OPEN_MATCH="$(jq --arg aid "audit-id: ${IDENTITY}" '
  [.items[]
   | select(.title | startswith("[codebase-audit:"))
   | select((.description // "") | contains($aid))
   | select(.status != "done")] | length' .scrum/backlog.json)"
DONE_MATCH="$(jq --arg aid "audit-id: ${IDENTITY}" '
  [.items[]
   | select(.title | startswith("[codebase-audit:"))
   | select((.description // "") | contains($aid))
   | select(.status == "done")] | length' .scrum/backlog.json)"

if [ "$OPEN_MATCH" -gt 0 ]; then
  # already tracked by an open PBI from this or an earlier Sprint — do
  # NOT file a duplicate; record the existing id in the report instead.
  EXISTING="$(jq -r --arg aid "audit-id: ${IDENTITY}" '
    .items[] | select((.description // "") | contains($aid))
    | select(.status != "done") | .id' .scrum/backlog.json | head -1)"
  echo "dedup: ${IDENTITY} already tracked by ${EXISTING}"
else
  REGRESS=""
  [ "$DONE_MATCH" -gt 0 ] && REGRESS="[REGRESSION] "   # closed then recurred
  .scrum/scripts/add-backlog-item.sh \
    --title "[codebase-audit:${SPRINT_ID}:${Fn}:${SEVERITY}] ${REGRESS}<summary>" \
    --description "${REGRESS}Codebase-audit ${Fn} (${SEVERITY}). audit-id: ${IDENTITY}. Occurrences: <path:line — symbol, one per line, ALL of them>. Sweep: <the search establishing the list is complete>. See ${REPORT}." \
    --ac "<expected vs actual per the class, independently verifiable>" \
    --kind <code|docs>
fi
```

- **Open match** → skip; note the existing PBI id in the report.
- **Done match, no open match** → the finding was fixed and has
  **regressed**; file a fresh PBI tagged `[REGRESSION]` and say so in
  the report.
- **No match** → file a new PBI.

Each AC states expected vs actual and is independently verifiable —
never a bare `grep` hit count. **A class PBI's AC closes the whole
class, not one site**: it carries the full occurrence list plus a
re-runnable zero-check derived from the sweep ("the sweep pattern
finds no remaining instance"), so fixing a subset of occurrences does
not satisfy the AC. `--kind docs` only when every occurrence is
confined to `**/*.md`; else `code` (the `DOCS` batch commonly mixes
`*.md` drift with in-source docstrings — then it is `code`). The
`audit-id: <identity>` line in the description is the dedup key — it
MUST be present and stable; a `[REGRESSION]` on a class identity means
the class recurred after being swept to zero.

### Step 6 — Close out per context

- **Context (a)** → report severity counts + PBIs filed / deduped /
  regressed to the PO. Return to the `cross-review` ceremony. Phase
  untouched.
- **Context (b)** → recompute `OPEN_CH` (Step 1b). `OPEN_CH == 0` →
  proceed (hand back to `integration-tests`, phase untouched).
  `OPEN_CH > 0` → route to `backlog_created` and report the blocking
  PBIs.

## Strict Rules

- **Read-only.** Auditors never edit code, docs, specs, or state.
  Verify `git status` clean after each auditor.
- **Whole-repo scope.** The audit target is the accumulated codebase at
  HEAD, not any Sprint or PBI diff. `base_sha` is context only.
- **Context (a) is non-blocking.** It never fails the Sprint and never
  transitions the phase. Only context (b) may set `backlog_created`,
  and only on an unresolved Critical/High.
- **No fix without a PBI.** Every actioned finding becomes a draft PBI
  through `.scrum/scripts/add-backlog-item.sh` — never a direct edit,
  never a raw `jq` write to `backlog.json`.
- **One PBI per defect class, swept to zero.** Never file
  occurrence-level PBIs for a repo-wide pattern: the class PBI
  enumerates every occurrence and its AC closes the whole class. A
  single-site fix of a multi-site class is the churn engine this rule
  removes.
- **Documentation drift always batches** into the single per-audit
  `DOCS` PBI — individual doc-fix PBIs are never filed.
- **Cross-Sprint dedup is content-based.** Match on the `identity` key
  in the PBI description, not the per-Sprint prefix. An open match →
  skip; a closed-then-recurred match → `[REGRESSION]` PBI. Never file a
  duplicate for an already-open finding.
- **Fact vs interpretation stay separated** in every finding.
- **Spec-vs-spec conflicts check the PO decision log first.**
- **Redundancy claims are grounded** — cite the static-analysis file
  when it exists; otherwise state the reachability reasoning and mark
  the finding lower-confidence.
- **`product-security` is whole-repo only** — the complement of the
  per-PBI diff-local security aspect (scope split: § Role).

## Exit Criteria

- **Context (a):** `.scrum/reviews/codebase-audit-s{N}.md` exists for
  the Sprint with all 4 axes represented, findings deduped (within
  audit), **merged to class level with complete occurrence lists (sweep
  recorded per class)**, severity-classified, fact separated from
  interpretation; documentation drift collapsed into the single `DOCS`
  batch. Every Critical/High class is either a new/regression draft PBI
  or deduped against an existing open PBI (id noted). Phase untouched.
- **Context (b):** either **proceed** (fresh report + no open
  Critical/High audit PBI → handed back, phase untouched) or **block**
  (open/newly-found Critical/High → `backlog_created`, blocking PBIs
  reported).
- `git status` clean (auditors made no edits).

## References

- [`references/axes.md`](references/axes.md) — common auditor protocol,
  the finding-return schema (incl. the `identity` dedup key), and the 3
  axis prompt templates.

Ref: FR-009 (cross-review, context (a)) + FR-013 (Integration Sprint
entry re-check, context (b)). The audit itself is a framework-level
quality mechanism layered onto both ceremonies.
