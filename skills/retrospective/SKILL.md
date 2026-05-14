---
name: retrospective
description: Sprint Retrospective — record improvements, consolidate periodically
disable-model-invocation: false
---

## Inputs

- state.json → phase: sprint_review
- improvements.json (existing improvements + last_consolidation_sprint)
- sprint.json (Sprint id)

## Outputs

- improvements.json → entries[] appended, stale entries archived every 3 Sprints
- state.json → phase: retrospective
- sprint.json → status: "complete"

## Preconditions

- state.json phase: "sprint_review"
- sprint.json exists

## Steps

1. state.json → phase: "retrospective":
   ```bash
   .scrum/scripts/update-state-phase.sh retrospective
   ```
2. Reflect on Sprint: what went well, what to improve (process, communication, tooling, code quality)
3. Record ≥1 improvement→improvements.json entries[]: id, sprint_id, **category**, description, status: "active", created_at.
   `category` is a free-form string but should be one of `{process, communication, tooling, code_quality, quality}` so consolidation and downstream framework feedback can group reliably.
4. **Flag framework-level improvements.** Any improvement whose root cause sits in the deployed scrum-team framework itself — wrapper scripts under `.scrum/scripts/*`, skill SKILL.md content, hooks, sub-agent definitions, schema files — **MUST** be tagged in its description with the literal prefix `[framework]`, e.g.:
   ```
   [framework] commit-pbi.sh の `git add -A -- ':!.scrum'` が git 2.36+ で rc=1 を返す。
   ```
   Without this tag the upstream framework owner has no efficient way to discover recurring breakage — target-project retrospectives are otherwise siloed inside each project's `.scrum/improvements.json` and never feed back. **Multi-sprint recurrence MUST be called out in the description** (e.g. "5 Sprint 連続再発: s21/24/27/29/31") so the upstream owner can prioritise by frequency, not by recency.
5. **Consolidation check**: Every 3 Sprints (compare last_consolidation_sprint)→archive stale entries (status: "archived", archived_at)→update last_consolidation_sprint. Do NOT archive `[framework]`-tagged entries that have not yet been confirmed fixed upstream — recurring framework bugs need to keep surfacing every retrospective until the root cause lands in the framework repo.
6. Present retrospective report: went well, to improve, archived items. **Surface the `[framework]`-tagged active entries in a separate dedicated section labelled "Framework feedback (upstream)" so the user can copy the list verbatim to the framework repository's tracker.**
7. sprint.json → status: "complete":
   ```bash
   .scrum/scripts/update-sprint-status.sh complete
   ```

Ref: FR-012

### 8. Session reset recommendation

After Sprint deliverables are committed and Retrospective is complete, recommend session reset to the user:

> "Sprint N complete. All state persisted to .scrum/ JSON files. Recommend `/clear` or session restart to free context for next Sprint. Session-context hook will restore phase automatically on restart."

**Rationale**: Scrum Master context accumulates across phases (requirements, design discussions, review findings). By Sprint end, context is near capacity. All durable state lives in `.scrum/` files — session-context.sh restores phase on restart.

## Exit Criteria

- ≥1 improvement recorded (all fields set)
- If consolidation due→archived + last_consolidation_sprint updated
- state.json phase: "retrospective"
- sprint.json status: "complete"
- Session reset recommended to user
