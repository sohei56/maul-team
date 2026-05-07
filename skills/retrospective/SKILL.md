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
3. Record ≥1 improvement→improvements.json entries[]: id, sprint_id, description, status: "active", created_at
4. **Consolidation check**: Every 3 Sprints (compare last_consolidation_sprint)→archive stale entries (status: "archived", archived_at)→update last_consolidation_sprint
5. Present retrospective report: went well, to improve, archived items
6. sprint.json → status: "complete":
   ```bash
   .scrum/scripts/update-sprint-status.sh complete
   ```

Ref: FR-012

### 7. Session reset recommendation

After Sprint deliverables are committed and Retrospective is complete, recommend session reset to the user:

> "Sprint N complete. All state persisted to .scrum/ JSON files. Recommend `/clear` or session restart to free context for next Sprint. Session-context hook will restore phase automatically on restart."

**Rationale**: Scrum Master context accumulates across phases (requirements, design discussions, review findings). By Sprint end, context is near capacity. All durable state lives in `.scrum/` files — session-context.sh restores phase on restart.

## Exit Criteria

- ≥1 improvement recorded (all fields set)
- If consolidation due→archived + last_consolidation_sprint updated
- state.json phase: "retrospective"
- sprint.json status: "complete"
- Session reset recommended to user
