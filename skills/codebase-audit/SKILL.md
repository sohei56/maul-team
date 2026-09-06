---
name: codebase-audit
description: >
  Whole-repo, multi-agent audit run by the Sprint-end cross-review
  every third Sprint (product-wide integrity): 4 axes — spec-conformance,
  logic/defect hunt, redundancy, and product-security — over the
  ACCUMULATED codebase at HEAD, not the Sprint diff. Findings are
  swept to zero per defect class — one class = one PBI covering every
  occurrence, documentation drift batched into a single DOCS PBI — and
  non-blocking: every ordinary finding is PO-adjudicated, Critical/High
  carrying a next-Sprint recommendation, while the DOCS batch is
  mandatory remediation. A rejected ordinary finding is suppressed
  with a recorded decision. At Integration-Sprint entry a thin re-check
  confirms the latest audit is fresh and no open blocking (non-Low)
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
| **(a) cross-review** (primary) | Every third Sprint (`N % 3 == 0`), embedded in the every-Sprint `cross-review` ceremony | **Non-blocking.** Never fails the Sprint, never transitions the phase. Every ordinary finding is PO-adjudicated (Step 4a); Critical/High carry a `next_sprint` recommendation, Low a `defer` one. The `DOCS` batch is mandatory file/reuse and the ceremony closes it inside the current Sprint (`../cross-review/SKILL.md` Step 7b) — documentation drift compounds while it waits. |
| **(b) integration entry** (thin re-check) | Once, at the top of `integration-tests` Step 1 | Verifies the latest audit is **fresh** and no open blocking (non-`low`) audit PBI remains. Both hold → proceed. Stale/missing → run a fresh audit; unresolved blocking PBIs → **block** and route to `backlog_created`. |

Context (a) is the audit's real home — findings are caught on the
three-Sprint cadence
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

The per-PBI pipeline runs a diff-local security aspect review on each
PBI before it reaches `awaiting_cross_review`. The audit's
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
  `acceptance_criteria`, `kind`, `audit_identity`) — for the
  spec-conformance axis to map requirements to implementation, for
  cross-PBI duplication reasoning, and for **cross-Sprint PBI dedup**
  (`audit_identity` on existing `[codebase-audit:*]` items). PBI
  `description` is **not** passed to the auditors — see Step 1.
- `.scrum/audit-ledger.json` — the defect-**class** ledger: every
  `identity`, `status`, `severity`, `occurrences[]`, `exclusions[]` and
  `detector`. It is the authoritative class list handed to the auditors
  and is strictly larger than the PBI summary, because a class outlives
  its PBI (`accepted` / `closed` / `guarded` classes have no open item).
  Read freely; every **write** goes through
  `.scrum/scripts/update-audit-ledger.sh` (run it with `--help` for the
  subcommand signatures), never a direct edit.
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
  fact-vs-interpretation separated, plus the **spec-exempted
  observations** section (what an enabled spec clause suppressed).
- Draft PBIs in `.scrum/backlog.json` via
  `.scrum/scripts/add-backlog-item.sh`, title prefix
  `[codebase-audit:<sprint-id>:F<n>:<Severity>]` and the
  `audit_severity` field (a `[REGRESSION]` tag is added when a
  previously-closed finding recurs). **The field is canonical**
  (`critical` / `high` / `low`, lowercase); the title suffix is a
  human-scannable snapshot taken at filing time, and
  `add-backlog-item.sh` requires the two to agree case-insensitively.
  Every block-check and re-rank reads the field.
  Filing granularity is **class-level, not occurrence-level**: one PBI
  per defect class covering every occurrence the sweep found (Step 3),
  plus, when documentation drift exists, exactly one filed/reused
  `[codebase-audit:<sprint-id>:DOCS:<Severity>]` batch PBI holding ALL
  documentation-drift findings of the audit. Which
  ordinary classes are filed is the PO's call (Step 4a); DOCS is
  mandatory. Created as `draft` →
  picked up by next Sprint's Backlog Refinement / Sprint Planning.
  **Non-blocking in context (a).** The `DOCS` batch is the exception:
  `cross-review` Step 7b refines it into the **current** Sprint and
  runs it to merge there.
- `.scrum/po/decisions.json` records, via
  `.scrum/scripts/append-po-decision.sh`, one `defect_triage` record per
  **suppressing** verdict (`defer` / `reject`) carrying the finding's
  `audit_identity` + `audit_severity`. A `next_sprint` verdict needs no
  record — the PBI it produces is the record.
- **Context (b) only, on an unresolved blocking (non-`low`) PBI or
  newly-found DOCS drift at any severity:**
  `state.json` phase → `backlog_created` via
  `.scrum/scripts/update-state-phase.sh`.
- `.scrum/audit-ledger.json` — one class entry per finding the audit
  saw, with its occurrence list, written in Step 3a **before** `$REPORT`,
  plus the Step 4a/5 status and link follow-ups. All via
  `.scrum/scripts/update-audit-ledger.sh`.
- `.scrum/reviews/audit-occurrences-s{N}.json` — the merged occurrence
  sets as transcribed (Step 3a), kept as the durable artifact behind the
  ledger write.
- A report to the user / PO (severity counts + PBIs created / skipped
  by dedup + regressions).
- When DOCS drift exists, a validated context handoff id:
  `CROSS_REVIEW_DOCS_PBI` for context (a), or
  `INTEGRATION_DOCS_PBI` for context (b).

**Output discipline.** Follow `../../rules/scrum-context.md` § Output
discipline — lead with the outcome, no preamble, no closing recap.

## Preconditions

- ≥1 Development Sprint has completed (there is accumulated code to
  audit). The audit is a no-op on an empty repo.
- `requirements.md` and the enabled design specs exist.
- Context (a): invoked only on a due Sprint inside the `cross-review`
  ceremony (see `../cross-review/SKILL.md` Steps 7–7a). Context (b): invoked at
  the top of `integration-tests` Step 1.

## PO Mode (po_mode: "agent")

Under `po_mode=agent`, every "ask the user" / "PO decides" phrase
below resolves to a `PO_DECISION_REQUEST` / `PO_DECISION` exchange
with the `product-owner` teammate, per the uniform rule in
`../../rules/scrum-context.md` § PO seat resolution (flow unchanged; never
block on human input). Skill-specific overrides:

| Context | Override (po_mode=agent) |
|------|--------------------------|
| (a) cross-review | Replace the PBI-routing prompt with `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[next_sprint,defer,reject]` carrying every **non-DOCS** finding, each with its severity and the decision-ready explanation of Step 4a; `recommendation=next_sprint` for critical/high, `defer` for low. The synthetic DOCS batch is mandatory file/reuse and proceeds to Step 7b, so it is reported but never offered as a waive choice. The PO returns a route per ordinary finding in one reply; `next_sprint` → file the draft PBI, `defer`/`reject` → do not file. Per-finding `defer`/`reject` verdicts are persisted via `append-po-decision.sh` **before** Step 5 runs. No human-input wait, non-blocking either way. When Axis A returned a class 1/3/4/5 finding, a **second** request follows (Step 4b): `kind=spec_clarification options=[fix_spec,fix_code,accept_as_is]` — which side is authoritative (class 5 narrows the options to `[fix_spec,accept_as_is]`). |
| (b) integration entry | A newly-found DOCS batch is **not** offered as a file/waive choice: Step 5 files or reuses it first, regardless of severity or any prior/current PO `defer`/`reject`, then Step 6 reports its PBI id and routes to `backlog_created`. For other unresolved blocking (non-`low`) PBIs, replace "inform the user of the block" with `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[fix_now,defer] recommendation=fix_now` carrying the blocking PBI list. That reply sets fix priority; it does not waive the block. |

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
- **`cross_review`** → the caller MUST first establish `N % 3 == 0`;
  skip Step 1b and run Steps 1–5 (invoked from
  the `cross-review` ceremony, Steps 7–7a, after it produced the
  static-analysis file).

### Step 1b — Integration-entry thin re-check (context (b) only)

```bash
FRESH_REPORT=".scrum/reviews/codebase-audit-s${N}.md"
# open audit PBIs rated as blocking — everything that is not `low`
# (done = fixed, cancelled = explicitly descoped by PO — neither is open)
OPEN_BLOCKING="$(jq '[.items[]
  | select(.title | startswith("[codebase-audit:"))
  | select((.audit_severity // "high") != "low")
  | select(.status != "done" and .status != "cancelled")] | length' .scrum/backlog.json)"
```

`audit_severity` is the canonical rating; the title's `:<Severity>]`
suffix is only the snapshot taken at filing time and is **not** read
here (an escalation re-rank in Step 5 updates the field, never the
title). A legacy item with no field defaults to blocking — the
fail-safe direction, and what migration 006 back-fills.

- **Fresh report exists AND `OPEN_BLOCKING == 0`** → **proceed**. Report
  "audit fresh (s${N}), no open blocking audit PBIs" and hand back
  to `integration-tests`. Do not run the axes.
- **Report stale / missing** (`$FRESH_REPORT` absent) → run a **fresh
  audit now**: continue into Steps 1–5 with `context=integration_entry`
  (Step 5 files PBIs with cross-Sprint dedup), then re-evaluate
  `OPEN_BLOCKING` and apply the block rule below.
- **`OPEN_BLOCKING > 0`** (audit PBIs filed in an earlier Sprint but not
  yet `done`) → **block**: route to the defect-fix loop
  (`.scrum/scripts/update-state-phase.sh backlog_created`), report the
  blocking PBI ids, and stop. This is the hole the re-check closes —
  audit PBIs that were filed but never fixed before integration.

`N` is the current sprint number, so a fresh Integration-Sprint re-entry
after a defect-fix loop (new sprint number) has no matching
`$FRESH_REPORT` and runs a fresh audit against the fixed code — intended.

The integration-entry preflight is mandatory and is **not cadence-
gated**. Its freshness target is always the current/final Development
Sprint named by `sprint.json.id`. Therefore a final non-due Sprint will
normally have no scheduled report and intentionally falls through to a
full audit here. Do not substitute the most recent older scheduled
report.

### Step 1 — Assemble the shared read set

Collect for the auditors: enabled spec IDs + files, `requirements.md`,
the PBI summary (`id`, `title`, `acceptance_criteria`, `kind`,
**`audit_identity`**), the **class ledger**, and the most recent
static-analysis file:
```bash
STATIC="$(ls .scrum/reviews/static-analysis-r*.json 2>/dev/null | sort -V | tail -1)"
# The class list handed to the auditors. Reading .scrum/audit-ledger.json is
# unrestricted; writing it is Step 3a's job, through the wrapper only.
LEDGER="$(jq -c '[.classes[]? | {identity, status, severity,
  exclusions: (.exclusions // []), has_detector: (.detector != null)}]' \
  .scrum/audit-ledger.json 2>/dev/null || printf '[]')"
```
Do NOT pass `.scrum/` pipeline state, dev communications, or PBI
descriptions beyond the fields above.

`audit_identity` and the ledger are in the read set for one reason: the
identity is the key the auditors themselves mint, and cross-Sprint dedup
matches on it exactly. An auditor that cannot see the keys already
minted re-invents a different string for the same defect class every
audit, and the class is filed again as new. The **ledger is the source
of truth** for that list; the PBI summary's `audit_identity` is the
filing-side key and is a subset of it. Pass both, `audit_identity`
included even when null — the auditors are told to reuse a ledger
identity byte-for-byte and mint only for a class the ledger does not
have (`references/axes.md`, `identity`).

**Scope handed to the auditors.** A class's ledger `status` decides
whether it is still theirs to detect. Hand each auditor this table with
the ledger:

| ledger `status` | auditor scope |
|---|---|
| `open`, `sweeping` | in scope |
| `guarded` | **excluded** — a registered detector owns the class ([`references/detectors.md`](references/detectors.md)). Nothing is dropped silently: the status is unreachable without a wired detector that actually executed. |
| `closed` **with** a `detector` | excluded |
| `closed` **without** a `detector` | **in scope** — re-detection is the only regression signal; a hit becomes a `[REGRESSION]` PBI (Step 5) |
| `accepted` | **in scope for detection**, excluded from *filing* at Step 5. Same reason as § Strict Rules "the audit never self-suppresses on a `defect_triage` record": the escalation re-open is only computable from a fresh rating. |

`exclusions[]` suppress per `(path, symbol)`, not per class — an excluded
site is out of scope inside an otherwise in-scope class. Tell the auditor
to report such an occurrence anyway, **citing that entry's `dec_id`**,
when it believes the waiver no longer holds: the audit neither silently
overrides a PO decision nor silently obeys a stale one.

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

Merge and classify here. `$REPORT` itself is **written at the end of
Step 3a**, after the classes are transcribed into the ledger, so its
occurrence lists are generated from the ledger and the two cannot
disagree. Report content:
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
  adding safety. The synthetic finding carries the **fixed identity
  `docs-drift::stale-references`** — the batch is one standing class, so
  a per-Sprint key would let a second open DOCS batch pile up beside the
  first while both describe the same thing. Step 5's open-match branch
  therefore *appends* to the existing batch instead of dropping the new
  occurrences (see Step 5). **Axis A class 5 never joins the batch**
  even though its fix is entirely documentation: it edits an enabled
  spec or `requirements.md`, which the `kind=docs` pipeline is denied
  and only `change-process` may touch (`../cross-review/SKILL.md`
  Step 7b).
- **Redundancy axis is static-analysis-grounded.** In context (a) the
  `redundancy` axis consumes the same two-pass static-analysis file
  cross-review produced (Pass A Sprint-diff lint + Pass B whole-repo
  reachability). The `redundancy` axis is the sole Sprint-level owner of
  whole-repo dead-code findings, so it must cite that file as ground
  truth (absent → reachability reasoning at lower confidence).
- **Severity** (table below) per distinct finding.
- Number findings `F1..Fn`; each carries axis(es), severity,
  `file:line`, `identity` key, fact, interpretation (labeled
  separately), and a one-line proposed fix / AC.
- **Spec-exempted observations.** Collect every `spec-exempted:` block
  the axes returned into one section, verbatim (`path::symbol` + clause
  + why it looks like a defect). Do not silently drop them and do not
  promote them to findings. They are the audit's record of what an
  enabled clause suppressed this Sprint: without it the same judgement
  is re-made from scratch — and re-decided differently — every audit,
  and a clause that is quietly load-bearing never becomes visible. A
  repeat across scheduled or integration-entry audits is the signal to re-examine the clause as an
  Axis A class 4 finding.
- Report structure: headline (total findings, count per severity) →
  severity-sorted finding table → per-finding detail → spec-exempted
  observations → **suppressed by PO decision** → **the
  clarification-backfill ledger** (Step 4c) → the derived / skipped /
  regression PBI list.
- **Suppressed by PO decision.** One row per finding this audit did not
  file because a recorded `reject` still holds (Step 5): the
  `audit_identity`, the `dec_id`, the verdict, the severity it was
  rejected at, and what would re-open it (a strictly higher rating, or
  a later `defect_triage` on the same identity). A suppression that
  leaves no trace in the report is indistinguishable from a finding
  nobody noticed. A suppressed or `cancelled` **critical** finding is
  additionally called out by name — the waiver has to be loud.

**Severity definitions:**
| Severity | Definition |
|---|---|
| **Critical** | A bug that prevents the spec from being met. |
| **High** | The spec is met, but leaving it unfixed causes future harm — a latent bug or accumulating debt. |
| **Low** | An improvement that need not be fixed. |

Ordering is `low < high < critical`. Two mechanisms compare severities:
the Step 1b block predicate (everything that is not `low` blocks) and
the Step 5 escalation re-open (a strictly higher rating lapses a
`reject` and re-ranks an open PBI). The lowercase enum
(`critical`/`high`/`low`) is what `audit_severity` stores; Title-case is
prose and the title suffix only.

### Step 3a — Transcribe the classes into the ledger, then write the report

Prose is a lossy transport for occurrence lists: measured in a local A/B
experiment, carrying them only through the report text collapsed 293
occurrences to 50 distinct paths and dropped sweep completeness from
36/36 to 29/36. So the ledger is written **first** and the report is
generated from it. Do this for **every** class the audit saw, including
ones the PO will later waive — Step 4 decides what is *filed*, never
what is *recorded*.

1. Persist the merged occurrence sets. `.scrum/reviews/*.json` is carved
   out of the scrum-state guard, so this heredoc needs no wrapper and
   leaves the transcription auditable next to the report:

   ```bash
   OCC=".scrum/reviews/audit-occurrences-s${N}.json"
   ONE=".scrum/reviews/audit-occurrences-s${N}-current.json"
   cat > "$OCC" <<'JSON'
   {
     "<identity>": [
       {"path": "<path>", "symbol": "<symbol or null>", "note": "<one line or null>"}
     ]
   }
   JSON
   ```

2. Per class: create-or-merge the class, then transcribe its
   occurrences. `upsert-class` unions the axes and raises severity
   monotonically; `add-occurrences` unions on `(path, symbol)` and
   stamps `last_seen_sprint`, so a site that has stopped appearing stays
   visible instead of vanishing:

   ```bash
   for IDENTITY in $(jq -r 'keys[]' "$OCC"); do
     .scrum/scripts/update-audit-ledger.sh upsert-class \
       --identity "$IDENTITY" --sprint "$SPRINT_ID" \
       --axis "<axis[,axis]>" --severity "<critical|high|low>"
     jq -c --arg k "$IDENTITY" '.[$k]' "$OCC" > "$ONE"
     .scrum/scripts/update-audit-ledger.sh add-occurrences \
       --identity "$IDENTITY" --sprint "$SPRINT_ID" --from "$ONE"
   done
   ```

   A malformed identity is **rejected, not repaired** — the wrapper
   applies the same normalization rule as `references/axes.md`
   § `identity`. Fix the finding's key and re-run; do not hand-normalize
   it, which is how two spellings of one class get created.

3. **Only now write `$REPORT`** — the Step 3 heredoc — reading each
   class's occurrence list back out of the ledger rather than out of the
   axis messages:

   ```bash
   jq -r --arg k "$IDENTITY" '.classes[] | select(.identity == $k)
     | .occurrences[] | "- \(.path)\(if .symbol then " — " + .symbol else "" end)"' \
     .scrum/audit-ledger.json
   cat > "$REPORT" <<'MD'
   <report per Step 3, occurrence lists from the query above>
   MD
   ```

### Step 4 — Route findings (PO)

Two separate requests. The first asks **whether to file**; the second
asks **which side is authoritative** — the code or the spec. Only the
PO can answer the second, and the audit must not answer it by default.

**4a — Defect triage (all axes).**

**Every ordinary finding is adjudicated.** In both contexts, remove the
synthetic DOCS finding from the PO's file/waive decision set. It is
mandatory remediation, not a product-priority choice: Step 5 files/reuses it
regardless of severity, prior suppression, or a PO `defer`/`reject`.
The PO may prioritize the resulting PBI but cannot waive the pre-test
fix loop. All non-DOCS findings retain the normal adjudication below.
What gets built next is a product-value call, so the PO rules on all of
them, `critical` included. The audit supplies the recommendation:
`next_sprint` for critical/high, `defer` for low. Send **one** request
carrying the whole list and take **one** reply with a per-finding route
(the batch shape protects the review-phase Stop budget; the log below is
the separate axis).

- **Decision-ready per-finding brief (obligation, not a second
  format).** The request references `$REPORT` and, per finding,
  restates in plain language: *what* it is, *why* it is a defect, the
  *impact* if left alone, and the *proposed fix* — with fact and
  interpretation kept separate exactly as the report already carries
  them (Step 3). A PO who cannot follow the finding cannot rule on it,
  and a request that reads as jargon gets rubber-stamped.
- **Persisting the suppressing verdicts.** For each finding the PO
  routes to `defer` or `reject`, append one record **before** Step 5
  runs:

  ```bash
  .scrum/scripts/append-po-decision.sh \
    --kind defect_triage --sprint "$SPRINT_ID" \
    --decision "<defer|reject>" \
    --request "codebase-audit ${Fn}: <one-line finding summary>" \
    --rationale "<the PO's own reason>" \
    --audit-identity "${IDENTITY}" --audit-severity "${SEVERITY}"
  ```

  `next_sprint` needs no record — the PBI is a strictly more informative
  one, and the PO's context restoration reads only the last 20
  decisions, so logging every routine "yes, file it" would evict real
  rationale within one audit. The wrapper **requires** both audit flags
  on a `reject` (guard (d)): a rejection is a persisted suppression that
  Step 5 must be able to match back to the finding it silenced.
- **`po_mode=human` — the SM records on the human's behalf.** There is
  no `AskUserQuestion` mechanism in this framework: the SM writes the
  batch question into the main session and **ends its turn**; the human
  answers on resume. The SM then parses the natural-language verdicts
  and runs the wrapper above once per `defer`/`reject` finding, with
  `--rationale` carrying the human's own words and **no**
  `--assumption` flag — the human did decide. This is the one place the
  SM writes a PO decision record, and it exists so suppression works
  identically in both modes.
- **Ledger follow-up for a suppressing verdict.** With the `dec_id`
  `append-po-decision.sh` returned in hand, record the verdict on the
  class so the auditors keep detecting it while Step 5 stops filing it:

  ```bash
  .scrum/scripts/update-audit-ledger.sh set-status \
    --identity "${IDENTITY}" --status accepted --dec-id "${DEC_ID}"
  ```

  When the waiver covers only some sites, it is a per-occurrence
  exclusion, not a class status — the rest of the class stays in scope:

  ```bash
  .scrum/scripts/update-audit-ledger.sh add-exclusion \
    --identity "${IDENTITY}" --path "<path>" --symbol "<symbol>" \
    --reason "<the PO's own reason>" --dec-id "${DEC_ID}"
  ```

  Both refuse a `dec_id` that is not in `.scrum/po/decisions.json`, so a
  suppression can never cite a decision nobody made.
- **Resume safety.** `$REPORT` and the ledger are both written in
  Step 3a, *before* the PO is asked, so a session restart resumes from a
  complete class list with no finding or occurrence lost.
- **Unanswered findings.** A finding the PO never ruled on is recorded
  in the report as *awaiting triage*: nothing is logged, nothing is
  filed, nothing is suppressed, and the next audit re-detects it. This
  is correct by construction — do **not** add a "default to file"
  fallback, which would restore the mandatory tier this step removed.

**4b — Spec adjudication (Axis A classes 1, 3, 4, 5).** A divergence, an
unadjudicated spec-vs-spec conflict, a spec-sanctions-a-defect finding,
and a spec carrying its own history all pose the same question, and
filing a code-fix PBI answers it silently in the code's favour. Put it
to the PO instead:

```
[sprint-<N>] PO_DECISION_REQUEST kind=spec_clarification
  options=[fix_spec,fix_code,accept_as_is] recommendation=<your read>
  <the clause + the code location + the sibling-implementation contrast
   + the clause's provenance (revision_history / change_process flag)>
```

`spec_clarification` is the existing decision kind for "which reading
governs" — no new kind is needed, and `decision` is free text, so the
verdict rides in it. Skip 4b when no Axis A class 1/3/4/5 finding
survived; do not raise it for class 2 (coded-but-unspecified) or for
the other three axes. **Class 5 differs in two ways:** its options are
`[fix_spec,accept_as_is]` (`fix_code` is meaningless — the finding makes
no claim about code), and the repo-wide `spec-history::body-changelog`
batch is **one** request covering every passage. A class-5 finding rated
High carries its own identity and gets its own request.

Routing of the verdict is Step 5. Context (a) is **non-blocking
regardless of severity** (per § Role) — do not transition the phase, do
not fail the Sprint, never revert a PBI.

### Step 4c — Backfill answered clarifications into the spec

Every `spec_clarification` the pipeline raised this Sprint is proof a
clause did not answer a question the work actually needed. The answer
reached the sub-agent and `.scrum/po/decisions.json`; the clause itself
is unchanged, so the next PBI to touch it asks again. Close that loop
here.

```bash
jq -r --arg s "$SPRINT_ID" '
  .decisions[]
  | select(.kind == "spec_clarification" and .sprint_id == $s)
  | "\(.id)\t\(.request)\t\(.decision)"' .scrum/po/decisions.json
```

For each row whose question named an enabled spec or `requirements.md`
clause:

1. Read the clause at HEAD. If the answer is now derivable from the
   clause as written, it was already backfilled — record `already
   current`.
2. Otherwise run `change-process` against that clause, with the
   decision as the reason and its `dec_id` in the request. This is the
   same `fix_spec` route as Step 5 and needs **no** second
   `spec_clarification` — the substance was already ruled; only the
   `change_request` approval gate applies.
3. Record per row in the report: `dec_id → clause → backfilled |
   already current | deferred (PO's reason)`.

**Do not do this mid-Sprint.** The clause lives on `main` while PBI
worktrees are forked from `sprint.base_sha`, so a mid-Sprint edit
reaches no in-flight worktree and races the merge queue. Answering the
question unblocks the Round; fixing the clause is Sprint-end work.

### Step 5 — Route the spec verdict, then file PBIs

**Step 4b verdicts first** — each Axis A class 1/3/4/5 finding takes one
of three exits, and only the middle one produces a PBI here (a class 5
finding is offered only the first and third):

| Verdict | Route |
|---|---|
| `fix_spec` | Run the **`change-process`** skill against the clause (it takes the `kind=change_request` approval, edits the doc, and appends the `revision_history` entry with `change_process: true` + the `dec_id`). Frozen is not exempt — that is what the Change Process is for. **Do not** file a pipeline PBI for the spec edit: `pbi-implementer` is denied writes to `docs/design/specs/` (`hooks/status-gate.sh`), and routing it as `kind=code` would put the UT and coverage gates on a documentation change. File a separate code PBI only if the implementation must move too. For a class 5 batch, one `change-process` run may cover every passage in the batch — one `change_request`, one `revision_history` entry per doc touched. |
| `fix_code` | File a normal class PBI below (`--kind code`). The spec stands. |
| `accept_as_is` | File nothing. The `spec_clarification` decision is now in `.scrum/po/decisions.json`, and Axis A classes 3 and 4 both skip an adjudicated clause — so the next audit will not re-raise it. Note the `dec_id` in the report and record it on the class: `update-audit-ledger.sh set-status --identity <k> --status accepted --dec-id <id>`. |

Record the verdict and `dec_id` per finding in the report, so a reader
can tell an unraised question from an answered one.

Build the Step 5 filing set as follows:

- ordinary class findings: only those the PO routed to `next_sprint`;
- in either context: the synthetic DOCS finding is added
  unconditionally, whether Low, High, or Critical and regardless of a
  PO `defer`/`reject`;
- in `integration_entry`, mark it `MANDATORY_INTEGRATION_DOCS`;
- in `cross_review`, call the same marker `MANDATORY_CROSS_REVIEW_DOCS`;
  Step 7b handles the filed/reused batch in the current Sprint.

For each finding in that set, file ONE draft PBI covering all of its
occurrences (the `DOCS` batch files the same way, as a single PBI).
The next scheduled or integration-entry audit must not spawn a
duplicate for an unfixed finding.
Dedup matches the finding's `identity` **exactly against the
`audit_identity` field** on existing audit PBIs — not the per-Sprint
title prefix, and not a substring of the description:

```bash
# IDENTITY, Fn, SEVERITY (Title-case, for the title), SUMMARY, AC, KIND
# from the finding. SEV is the canonical lowercase field value — derived,
# never typed twice, because the wrapper rejects a title/field disagreement.
SEV="$(printf '%s' "$SEVERITY" | tr '[:upper:]' '[:lower:]')"

# PO suppression: the LAST defect_triage verdict for this identity wins, so a
# later verdict supersedes an earlier reject with no "un-reject" verb.
# Skipped for the fixed DOCS identity — one reject there would blind the
# documentation-drift channel permanently.
SUPPRESSED=""
if [ "$IDENTITY" != "docs-drift::stale-references" ] && [ -f .scrum/po/decisions.json ]; then
  SUPPRESSED="$(jq -r --arg aid "$IDENTITY" '
    [.decisions[] | select(.kind == "defect_triage") | select(.audit_identity == $aid)]
    | last // empty | select(.decision == "reject") | "\(.id) \(.audit_severity)"' \
    .scrum/po/decisions.json)"
fi
# A non-empty $SUPPRESSED gates everything below — apply the branch table that
# follows this block before filing anything.

OPEN_MATCH="$(jq --arg aid "$IDENTITY" '
  [.items[]
   | select(.title | startswith("[codebase-audit:"))
   | select(.audit_identity == $aid)
   | select(.status != "done" and .status != "cancelled")] | length' .scrum/backlog.json)"
DONE_MATCH="$(jq --arg aid "$IDENTITY" '
  [.items[]
   | select(.title | startswith("[codebase-audit:"))
   | select(.audit_identity == $aid)
   | select(.status == "done")] | length' .scrum/backlog.json)"

if [ "$OPEN_MATCH" -gt 0 ]; then
  # already tracked by an open PBI from this or an earlier Sprint — do
  # NOT file a duplicate; record the existing id in the report instead.
  EXISTING="$(jq -r --arg aid "$IDENTITY" '
    .items[]
    | select(.title | startswith("[codebase-audit:"))
    | select(.audit_identity == $aid)
    | select(.status != "done" and .status != "cancelled") | .id' .scrum/backlog.json | head -1)"
  echo "dedup: ${IDENTITY} already tracked by ${EXISTING}"
  RESULT_PBI="$EXISTING"
else
  REGRESS=""
  [ "$DONE_MATCH" -gt 0 ] && REGRESS="[REGRESSION] "   # closed then recurred
  RESULT_PBI="$(.scrum/scripts/add-backlog-item.sh \
    --title "[codebase-audit:${SPRINT_ID}:${Fn}:${SEVERITY}] ${REGRESS}<summary>" \
    --audit-identity "${IDENTITY}" \
    --audit-severity "${SEV}" \
    --description "${REGRESS}Codebase-audit ${Fn} (${SEVERITY}). Occurrences: <path:line — symbol, one per line, ALL of them>. Sweep: <the search establishing the list is complete>. See ${REPORT}." \
    --ac "<the three-line AC template below>" \
    --kind <code|docs>)"
  # Only the file branch links: on the reuse branch the open PBI is already
  # in the class's pbi_ids (linked when it was filed, or seeded by migration).
  .scrum/scripts/update-audit-ledger.sh link-pbi \
    --identity "${IDENTITY}" --pbi "${RESULT_PBI}" --role sweep
fi

# Both branches: the class now has a live PBI working it.
.scrum/scripts/update-audit-ledger.sh set-status \
  --identity "${IDENTITY}" --status sweeping
```

`add-backlog-item.sh` refuses an `--audit-identity` that the ledger does
not carry, so Step 3a is a hard precondition for filing, not a habit.
The error names the `upsert-class` call that fixes it.

For either mandatory DOCS marker, execute the fixed-DOCS branch above
even if Step 4a or an older decision says `defer`/`reject`: suppression
is deliberately bypassed. The normal `OPEN_MATCH` logic is the required
**reuse** path (append the new occurrences below); no open match is the
required **file** path. Both branches MUST leave the id in
`RESULT_PBI`. After the DOCS append/re-rank work completes, save the
handoff explicitly and validate it:

```bash
if [ "$context" = "cross_review" ]; then
  CROSS_REVIEW_DOCS_PBI="$RESULT_PBI"
  [ -n "$CROSS_REVIEW_DOCS_PBI" ] || { echo "contract violation: missing CROSS_REVIEW_DOCS_PBI" >&2; return 1; }
else
  INTEGRATION_DOCS_PBI="$RESULT_PBI"
  [ -n "$INTEGRATION_DOCS_PBI" ] || { echo "contract violation: missing INTEGRATION_DOCS_PBI" >&2; return 1; }
fi
```

The caller receives that context-specific id together with the report.
This exception changes neither PO adjudication nor suppression for
non-DOCS findings.

- **`SUPPRESSED` non-empty and this audit's `$SEV` is NOT strictly
  higher than the recorded one** → do **not** file. Record
  `suppressed by <dec-id>` in the report's suppression section.
- **`SUPPRESSED` non-empty and `$SEV` is strictly higher**
  (`low < high < critical`) → the suppression lapses. Re-raise the
  finding in this Sprint's Step 4a batch tagged
  `[RE-RAISED: <old>→<new> since <dec-id>]` and route it by the new
  verdict. The PO rejected a smaller defect than the one now on the
  table.
- **Open match** → skip; note the existing PBI id in the report. If the
  open PBI's `audit_severity` is **strictly lower** than `$SEV`,
  re-rank it first — otherwise the Step 1b block-check keeps consulting
  a stale rating and a class that has become blocking silently is not:

  ```bash
  .scrum/scripts/set-backlog-item-field.sh "$EXISTING" audit_severity "$SEV"
  ```

  The title is deliberately **not** rewritten; the field is canonical
  and the suffix is the filing-time snapshot. Note the escalation in
  the report.
- **Done match, no open match** → the finding was fixed and has
  **regressed**; file a fresh PBI tagged `[REGRESSION]`, say so in the
  report, and re-open the class before the filing block's `sweeping`
  follow-up runs:

  ```bash
  .scrum/scripts/update-audit-ledger.sh upsert-class \
    --identity "${IDENTITY}" --sprint "${SPRINT_ID}" --severity "${SEV}"
  .scrum/scripts/update-audit-ledger.sh set-status \
    --identity "${IDENTITY}" --status open
  ```

  `upsert-class` raises severity monotonically and never lowers it, so a
  class that regressed at a higher rating keeps the higher one.
- **No match** → file a new PBI.

`cancelled` counts as **not open**, matching the Step 1b block-check: a
PBI the PO explicitly descoped must not suppress re-detection of its
class forever, and it must still be able to come back as a
`[REGRESSION]`.

**The `DOCS` batch is the one exception to "open match → skip."** Its
identity is fixed (`docs-drift::stale-references`), so an open batch
matches every audit. Skipping would silently discard the new drift, so
append to the existing PBI instead — read its current description, add
the new occurrences, and write it back:

```bash
CUR="$(jq -r --arg id "$EXISTING" '.items[] | select(.id == $id) | .description // ""' .scrum/backlog.json)"
.scrum/scripts/set-backlog-item-field.sh "$EXISTING" description \
  "${CUR}
Additional occurrences found in ${SPRINT_ID}: <path:line — symbol, one per line>. See ${REPORT}."
```

**AC template (three lines, all mandatory).** Each AC states expected vs
actual and is independently verifiable — never a bare `grep` hit count.
**A class PBI's AC closes the whole class, not one site**, so fixing a
subset of occurrences does not satisfy it:

```
--ac "The class <identity> cannot recur: <mechanism-level expected vs actual>.
Zero-check: <re-runnable sweep pattern> reports no instance at HEAD.
Not closed by this check: <occurrence kinds the zero-check cannot see>."
```

The third line is required whenever a detector exists or the sweep
pattern is narrower than the class; when nothing is out of scope it
reads `Not closed by this check: none`. It exists because a zero-check
is almost always narrower than the class it stands for, and applying one
verbatim as if it were the class is how a partly-swept class gets
recorded as closed (measured in a local A/B experiment). `--kind docs`
only when every occurrence is confined to `**/*.md`; else `code` (the
`DOCS` batch commonly mixes `*.md` drift with in-source docstrings —
then it is `code`).

**Machine-checkable class → file the pair, ratchet first.** When the
class can be decided by a bounded, deterministic command — contract in
[`references/detectors.md`](references/detectors.md) — Step 5 files
**two** PBIs under the same identity, detector before sweep:

1. **Detector PBI**, `link-pbi --role detector`:

   ```bash
   DET_PBI="$(.scrum/scripts/add-backlog-item.sh \
     --title "[codebase-audit:${SPRINT_ID}:${Fn}:${SEVERITY}] detector: <class>" \
     --audit-identity "${IDENTITY}" --audit-severity "${SEV}" --kind code \
     --description "Ratchet for ${IDENTITY}. See ${REPORT}." \
     --ac "A command exists that exits non-zero on a synthetic violation of ${IDENTITY} and 0 at clean HEAD; it runs in under <N> s and writes no files.
   .scrum/scripts/update-audit-ledger.sh register-detector --identity ${IDENTITY} --command '<cmd>' --sprint ${SPRINT_ID} succeeds.
   Not closed by this check: <occurrence kinds the detector cannot see>.")"
   .scrum/scripts/update-audit-ledger.sh link-pbi \
     --identity "${IDENTITY}" --pbi "${DET_PBI}" --role detector
   ```

   File it inside the `else` (no open match) arm above, **before** the
   sweep PBI: the ratchet lands first so the sweep has something to
   verify against.

2. **Sweep PBI** — the ordinary class PBI above, `--role sweep`, its AC
   additionally naming the detector's zero report.

`OPEN_MATCH` is computed once, before either is filed, so the pair files
together; a **later** audit sees an open match on the shared identity and
files nothing more — correct, not a collision. Do **not** promote the
class to `guarded` here: a command registered from a worktree does not
exist on `main` yet, so registration and promotion happen after the
detector PBI merges (`../pbi-merge/SKILL.md`).

`--audit-identity` is the dedup key and is **required** by the wrapper
for a `[codebase-audit:*]` title (it fails `E_INVALID_ARG` without it).
It lives in its own field rather than in the description because the
description is not passed to the auditors and may be rewritten wholesale
by refinement — both of which silently broke the key before. A
`[REGRESSION]` on a class identity means the class recurred after being
swept to zero.

### Step 6 — Close out per context

- **Context (a)** → report severity counts + PBIs filed / deduped /
  regressed / suppressed to the PO. Return to the `cross-review`
  ceremony. Phase untouched.
- **Context (b)** → if the fresh audit found documentation drift, its
  already-filed/reused `INTEGRATION_DOCS_PBI` MUST enter the normal defect-fix loop before any
  integration test starts, regardless of `audit_severity`: set
  `.scrum/scripts/update-state-phase.sh backlog_created`, report
  `$INTEGRATION_DOCS_PBI`, and stop. The PBI is then
  refined and completed through the existing `kind=docs` pipeline
  (Integrity aspects 1 + 5), or `kind=code` when the path boundary
  requires it. Integration entry resumes only after that PBI is
  `done`; the new current/final Sprint id then requires a fresh report.
  This is the integration-entry analogue of cross-review Step 7b, but
  uses the normal fix-loop state model rather than creating in-progress
  work inside `integration_sprint`.
  Otherwise recompute `OPEN_BLOCKING` (Step 1b).
  `OPEN_BLOCKING == 0` → proceed (hand back to `integration-tests`,
  phase untouched). `OPEN_BLOCKING > 0` → route to `backlog_created`
  and report the blocking PBIs. Either way, name every `critical`
  finding that a PO `reject` suppressed or a `cancelled` PBI descoped
  in the close-out line: the PO may waive a Critical, but the waiver
  must be visible at the gate it walks past, not only in the audit
  report.

## Strict Rules

- **Read-only.** Auditors never edit code, docs, specs, or state.
  Verify `git status` clean after each auditor.
- **Whole-repo scope.** The audit target is the accumulated codebase at
  HEAD, not any Sprint or PBI diff. `base_sha` is context only.
- **Context (a) is non-blocking.** It never fails the Sprint and never
  transitions the phase. Only context (b) may set `backlog_created`,
  on an unresolved blocking (non-`low`) audit PBI **or on a newly-found
  DOCS batch at any severity**.
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
- **Transcribe before you report.** Every class the audit sees is
  written into `.scrum/audit-ledger.json` through
  `.scrum/scripts/update-audit-ledger.sh` in Step 3a — **before**
  `$REPORT` is written — and the report's occurrence lists are generated
  from the ledger, so the two cannot disagree. Identities are reused
  **byte-for-byte** from the ledger; a class the ledger does not carry is
  the only case where one is minted. The ledger is never written by hand:
  the scrum-state guard blocks a direct edit, and the wrapper rejects a
  malformed identity rather than repairing it.
- **Cross-Sprint dedup keys on `audit_identity`.** Match the finding's
  identity exactly against the `audit_identity` field, not the
  per-Sprint prefix and not a substring of the description. An open
  match → skip; a closed-then-recurred match → `[REGRESSION]` PBI;
  `cancelled` is not open. Never file a duplicate for an already-open
  finding.
- **A PO rejection is a recorded suppression, never a silent drop.** It
  is logged with its `audit_identity` and the severity it was rejected
  at, listed in the report's suppression section, and lapses the moment
  a later audit rates the class strictly higher.
- **The audit never self-suppresses on a `defect_triage` record.** Only
  Step 5 consults them. The axes keep detecting and re-rating a rejected
  class every audit — the escalation re-open is only computable from a
  fresh rating.
- **Fact vs interpretation stay separated** in every finding.
- **Spec-vs-spec conflicts check the PO decision log first.**
- **The audit never decides which side is authoritative.** A spec
  divergence, an unadjudicated conflict, and a clause that sanctions a
  defect all go to the PO as `spec_clarification` (Step 4b). Filing a
  code-fix PBI without asking silently rules for the code — the one
  outcome the audit is not entitled to choose. A `fix_spec` verdict is
  executed by the `change-process` skill, including on frozen docs;
  never by a pipeline PBI.
- **Redundancy claims are grounded** — cite the static-analysis file
  when it exists; otherwise state the reachability reasoning and mark
  the finding lower-confidence.
- **`product-security` is whole-repo only** — the complement of the
  per-PBI diff-local security aspect (scope split: § Role).

## Exit Criteria

- **Context (a), due Sprints only:** `.scrum/reviews/codebase-audit-s{N}.md` exists for
  the Sprint with all 4 axes represented, findings deduped (within
  audit), **merged to class level with complete occurrence lists (sweep
  recorded per class)**, severity-classified, fact separated from
  interpretation; documentation drift collapsed into the single `DOCS`
  batch; every `spec-exempted:` block returned by an axis carried into
  the report's spec-exempted section. **Every finding has a recorded
  disposition**: filed as a new/regression draft PBI, deduped against an
  existing open PBI (id noted), suppressed by a named `dec_id`, or
  recorded as awaiting triage. **Every class is in
  `.scrum/audit-ledger.json` with its occurrence list** (Step 3a), and
  every filed PBI is linked to its class with a role. Phase untouched.
- **Context (b):** either **proceed** (fresh report + no open blocking
  (non-`low`) audit PBI → handed back, phase untouched) or **block**
  (open/newly-found blocking PBI, or newly-found documentation drift at
  any severity → `backlog_created`, blocking PBIs reported).
- `git status` clean (auditors made no edits).

## References

- [`references/axes.md`](references/axes.md) — common auditor protocol,
  the finding-return schema (incl. the `identity` dedup key), and the 3
  axis prompt templates.
- [`references/detectors.md`](references/detectors.md) — the detector
  contract (command shape, exit codes, timeout) behind the issuance pair
  and every `guarded` class.
- `.scrum/scripts/update-audit-ledger.sh --help` — the ledger subcommand
  signatures. This skill names only the calls it makes; the wrapper is
  the SSOT for their flags and refusals.

Ref: FR-009 (cross-review, context (a)) + FR-013 (Integration Sprint
entry re-check, context (b)). The audit itself is a framework-level
quality mechanism layered onto both ceremonies.
