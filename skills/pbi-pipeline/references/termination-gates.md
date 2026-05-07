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
| Budget cap (future) | (cumulative token > threshold) | STOP escalate (`budget_exhausted`) |

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

## Gate evaluation order

1. If success criteria met → STOP success (no further checks)
2. If stagnation → STOP escalate (stagnation)
3. If divergence → STOP escalate (divergence)
4. If hard cap → STOP escalate (max_rounds)
5. Otherwise: proceed to next Round (or build feedback first for the
   impl/pbi-review/ut-run cycle)
