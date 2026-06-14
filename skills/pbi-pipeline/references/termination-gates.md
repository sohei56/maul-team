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
- **Impl stage hard cap**: same as kind=code (`impl_round >= 5`).
  doc-only PBIs that can't converge in 5 impl rounds usually mean
  the parent finding was mis-framed; escalating to the SM is
  correct.

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
INCLUDING Rounds added after a Cross Review revert. `impl_round` is
the sole counter and is owned by `begin-impl-round.sh`; the wrapper
makes monotonic advance the only legal operation. A PBI that exceeds
5 impl Rounds — whether by internal review FAILs or by Sprint-end
Cross Review reverts — escalates and returns judgement to SM / PO.
This is intentional: more rounds usually means the requirement /
design is wrong, not that the implementer needs more tries.

## Cross Review re-entry boundary

When a Sprint-end Cross Review aspect 1/2/3 FAIL reverts a PBI to
`in_progress_impl`, the new Round that follows it is the FIRST
Round whose "prior review" is an aspect reviewer output, not a
codex-impl / codex-ut reviewer output. Concretely:

- Stagnation detection compares Critical/High signatures from
  Round n and Round n-1. Signatures from Cross Review aspect
  reviewers (`.scrum/reviews/aspect-*-review.md`) and PBI Review
  reviewers (`.scrum/pbi/<id>/impl/review-r{n-1}.md`,
  `.scrum/pbi/<id>/ut/review-r{n-1}.md`) are produced by different
  agents with different output conventions and are NOT comparable.
  → Skip Stagnation detection in that one Round.
- Divergence and Hard cap continue to apply (they count, not
  compare signatures).

After that first post-revert Round completes a normal PBI Review
cycle, Stagnation detection resumes normally for subsequent Rounds.

## Gate evaluation order

1. If success criteria met → STOP success (no further checks)
2. If stagnation → STOP escalate (stagnation)
3. If divergence → STOP escalate (divergence)
4. If hard cap → STOP escalate (max_rounds)
5. Otherwise: proceed to next Round (or build feedback first for the
   impl/pbi-review/ut-run cycle)
