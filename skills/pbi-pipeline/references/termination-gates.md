# Termination Gates Reference

Composite gate model used at end of each Round (design and the
impl/pbi-review/ut-run cycle). Anthropic + Ralph + GAN-derived.
Deterministic — no fuzzy heuristics.

> **Scope note**: termination gates here are **semantic success
> criteria** evaluated by the pipeline conductor at end of each Round
> (when to stop a Round: success / stagnation / divergence / hard cap).
> Distinct from `hooks/completion-gate.sh` and `hooks/quality-gate.sh`
> which validate **durable state** (state files exist, schemas match,
> status transitions are legal). The hooks gate Claude Code lifecycle
> events; these gates gate Round flow. They do not duplicate.

## Gate matrix

| Gate | Condition | Outcome |
|---|---|---|
| Success | (stage-specific success criteria all true) | STOP success |
| Tech-error recurrence | Same root web-searchable technical error in 2 consecutive Rounds AND `websearch_attempted` unset | Set latch; conductor runs the web search and folds findings into the next Round's feedback (no escalate). See § Technical-error recurrence |
| Stagnation | Same `signature` repeats in 2 consecutive Rounds (Critical/High only) | STOP escalate (`stagnation`) |
| Divergence | (CRITICAL+HIGH count) increases Round n → n+1 | STOP escalate (`divergence`) |
| Hard cap | `round_n >= 5` | STOP escalate (`max_rounds`) |
| Budget cap | (cumulative token > threshold) | STOP escalate (`budget_exhausted`) — the value is live: schema accepts it, `update-pbi-state.sh` writes it, and `pbi-escalation-handler` matches it as "Immediate human-escalate". The threshold itself is operator-configurable (no gate code wires up the comparison yet); declare a target via `.scrum/config.json` to enable. |

## Status transition on escalation

When any escalate gate fires:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason "<reason>"
.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
```

The new backlog status is `escalated` regardless of which stage the
gate fired in (`in_progress_design / impl / pbi_review / ut_run`).
SM picks it up via the `pbi-escalation-handler` skill.

## Stage-specific success criteria

- **Design stage**: `design-reviewer.verdict == PASS`
- **PBI Review stage**: both `codex-impl-reviewer.verdict == PASS` and
  `codex-ut-reviewer.verdict == PASS`
- **UT Run stage**: see `coverage-gate.md` § Pass criteria
  (test failures + coverage thresholds + pragma audit)
- **Integrity stage** (`integrity-stage.md`): every spawned aspect
  reviewer's `verdict == PASS` — i.e. **no Critical/High finding
  across any aspect**. kind=code spawns all 5 aspects; kind=docs spawns
  aspects 1 + 5 only. Medium/Low findings are recorded, non-blocking.

### Integrity stage — gate wiring

The Integrity stage runs at the tail of the Round (after UT Run PASS
for kind=code, after impl-reviewer PASS for kind=docs) and does **not**
have its own Round counter — it reuses `impl_round` (`$n`). An
Integrity FAIL reverts to `in_progress_impl`, and the next
`begin-impl-round.sh` increments `impl_round`, so the **hard cap
(`impl_round >= 5`) bounds the Integrity retry loop** with no new
counter regime.

Stagnation and Divergence for the Integrity stage operate on the
**union of all spawned aspect reviewers' findings** for the Round —
the aggregate the conductor persisted to
`.scrum/pbi/<id>/metrics/integrity-r{n}.json` (Critical/High only),
exactly as the PBI Review stage builds its set from the union of both
codex reviewers. The "prior review" for the comparison is the previous
Round's `integrity-r{n-prev}.json` (the last Round that reached the
Integrity stage).

### Integrity stage re-entry boundary

A Round only reaches the Integrity stage after its UT Run (kind=code)
or impl-reviewer (kind=docs) PASSes. A Round that failed earlier (at
PBI Review or UT Run) produces **no** `integrity-r{n}.json`, so the
"prior Round" for Stagnation may be several Rounds back or absent:

- **Stagnation** compares Critical/High signatures between the current
  Round's integrity aggregate and the **most recent prior Round that
  produced one**. If no comparable prior aggregate exists (this is the
  first Round to reach the Integrity stage), skip Stagnation for this
  Round — you cannot detect a repeat with nothing to compare against.
- **Divergence** and **Hard cap** always apply (they count, not
  compare), using the same integrity aggregate.

### kind=docs overrides

When `backlog.json items[].kind == "docs"`:

- **Design stage**: not run. No gate fires; `design_status` stays
  `skipped`. The hard-cap `design_round >= 5` cannot trigger because
  `design_round` stays at 0 throughout.
- **PBI Review stage**: success criterion is `codex-impl-reviewer.verdict
  == PASS` (single-reviewer; codex-ut-reviewer is not spawned).
  Stagnation and divergence are evaluated on the impl-reviewer's
  findings alone — the signature set is a strict subset of the kind=code
  path so the same algorithms apply unchanged.
- **UT Run stage**: not run. No gate fires; `ut_status` and
  `coverage_status` stay `skipped`.
- **Integrity stage**: runs aspects 1 (requirement-conformance) + 5
  (docs-consistency) only. Success = both `verdict == PASS`.
  Stagnation/Divergence evaluate on the union of those two aspects'
  findings — a strict subset of the kind=code aspect set, so the same
  algorithms apply unchanged.
- **Impl stage hard cap**: same as kind=code (`impl_round >= 5`).
  doc-only PBIs that can't converge in 5 impl rounds usually mean
  the parent finding was mis-framed; escalating to the SM is
  correct.

## Technical-error recurrence (web-search remediation)

Purpose: when a Developer keeps producing ineffective fixes against the
**same web-searchable technical error** (build/compile failure, runtime
exception, library/API misuse, test-tooling failure), have the
**conductor** research it once via `WebSearch` and hand the verified
findings to the implementer, instead of letting the error churn silently
to the hard cap. Only the conductor (Developer) has the `WebSearch`
tool; the impl / UT sub-agents do not. Latched to at most one
remediation Round per PBI.

Evaluated only when control is about to loop into the next impl Round
(a reviewer-FAIL or UT-run-FAIL where no escalate gate fired). It never
overrides Success.

### Technical-error set (web-searchable; machine-derived)

A finding counts as a web-searchable technical error iff it is one of:

- a `test-results-r{n}.json` `failures[]` entry with
  `type ∈ {exec_error, uncaught_exception, timeout}`. **`type ==
  assertion` is EXCLUDED** — an assertion failure is a logic/spec
  mismatch the design must resolve, not something a web search answers.
- a reviewer finding whose `signature` ends in `:error_handling` — the
  sole `criterion_key` that maps to a library/API contract. Every
  other `criterion_key` in the impl/UT reviewer vocabularies (full
  enum: `docs/contracts/pbi-pipeline-envelope.schema.json`) is
  spec/style and is NOT in this set. The suffix match is on
  `:error_handling` including the colon, so the design-stage key
  `missing_error_handling` (signature suffix
  `:missing_error_handling`) does NOT match.

### Recurrence judgment (the one bounded LLM call in this gate set)

The rest of these gates are deterministic. This one is not, because
test-failure `message` / `stack_trace` are free text (paths, line
numbers, addresses vary run to run), so a brittle string match is
unreliable. Instead the conductor reads the technical-error set of
Round n and Round n-1 and answers a SINGLE yes/no:

> Is the **same root technical error** present in both Rounds?

Restrict the judgment strictly to the technical-error set above. Never
let an assertion failure or a spec/style `criterion_key` enter this
judgment — those belong to Stagnation/Divergence, which escalate.

Unlike Stagnation, this gate does **not** need the Integrity-stage
re-entry skip: `test-results-r{n}.json` is uniformly schema'd, so Round
n and n-1 are comparable even across a Round that reverted from the
Integrity stage (only reviewer *prose* is incomparable there).

### Outcome

When recurrence is "yes" and the latch is unset, the **conductor**
performs the web search itself and records the findings into the next
Round's feedback file. The `websearch_attempted` latch records that the
**conductor performed the search** for this PBI (at most once). The
impl / UT sub-agents never call `WebSearch` — they only apply the
findings the conductor pasted into their feedback.

```bash
# recurrence == "yes":
if [ "$(jq -r '.websearch_attempted // false' "$STATE_FILE")" != "true" ]; then
  .scrum/scripts/update-pbi-state.sh "$PBI_ID" websearch_attempted true
  .scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" gate \
    "web-search remediation → next round"
  # Conductor-side action: run WebSearch NOW on the recurring error
  # (error text + library name/version + framework), then paste the
  # findings — root cause, verified fix guidance, and source URLs —
  # into the `## Web-search remediation` section of the next Round's
  # feedback file(s). See feedback-routing.md § Web-search remediation.
  # Do NOT escalate. Fall through to the normal FAIL → next-round path;
  # the sub-agent applies the pasted findings (it cannot search itself).
fi
# If websearch_attempted is already true, the single remediation Round
# was already spent: take NO special action here and let the Stagnation
# / Divergence / Hard-cap gates below decide escalation as usual. The
# latch bounds the added cost to at most +1 Round per PBI.
```

Documented limitation: the latch is per-PBI, not per-distinct-error. If
a second, unrelated technical error appears after the latch is set, it
does not get its own remediation Round — the existing gates handle it.

## Stagnation detection

```bash
# Build set of signatures for Round n (Critical/High only)
sig_n="$(jq -r '
  .findings | map(select(.severity == "critical" or .severity == "high"))
  | map(.signature) | sort | .[]
' "$CURRENT_REVIEW")"

# Same for Round n-1
sig_prev="$(jq -r '...' "$PREVIOUS_REVIEW")"

# Stagnation if any signature appears in both sets
common="$(comm -12 <(echo "$sig_n") <(echo "$sig_prev"))"
if [ -n "$common" ]; then
  echo "stagnation"
  exit 0
fi
```

For the PBI Review stage, build the set from BOTH impl and ut review
files (union).

## Divergence detection

```bash
count_n="$(jq '
  [.findings[] | select(.severity == "critical" or .severity == "high")] | length
' "$CURRENT_REVIEW")"
count_prev="$(jq '...' "$PREVIOUS_REVIEW")"
if [ "$count_n" -gt "$count_prev" ]; then
  echo "divergence"
fi
```

For the PBI Review stage, count from BOTH reviews (sum).

## Hard cap

```bash
if [ "$ROUND" -ge 5 ]; then
  echo "max_rounds"
fi
```

The hard cap is **cumulative** across the impl/PBI-review/UT-run cycle
INCLUDING Rounds added after an Integrity-stage revert. `impl_round` is
the sole counter and is owned by `begin-impl-round.sh`; the wrapper
makes monotonic advance the only legal operation. A PBI that exceeds
5 impl Rounds — whether by internal review FAILs or by Integrity-stage
reverts — escalates and returns judgement to SM / PO.
This is intentional: more rounds usually means the requirement /
design is wrong, not that the implementer needs more tries.

## Gate evaluation order

1. If success criteria met → STOP success (no further checks)
2. If technical-error recurrence (same root web-searchable error in 2
   consecutive Rounds) AND `websearch_attempted` is unset → set the
   latch, have the conductor run the web search, and fold its findings
   into the next Round's feedback (no escalate); skip the escalation
   checks below for this Round. If the latch is already set, continue to
   step 3.
3. If stagnation → STOP escalate (stagnation)
4. If divergence → STOP escalate (divergence)
5. If hard cap → STOP escalate (max_rounds)
6. Otherwise: proceed to next Round (or build feedback first for the
   impl/pbi-review/ut-run cycle)

Step 2 only redirects; it never stops. A web-search remediation Round
still counts toward the hard cap (step 5), so the latch can add at most
one Round before the cap forces escalation.
