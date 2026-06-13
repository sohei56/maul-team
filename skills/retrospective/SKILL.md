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

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, the human is not at
the keyboard, so the Step 7 "recommend `/clear` or session restart
to the user" line cannot be acted on by anyone in-session. Session
recycling is the responsibility of the autonomy watchdog
(`scripts/autonomous/watchdog.sh`), which restarts the SM session
once the current one terminates and the project phase is not
`complete`. This section is a no-op when `po_mode` is absent or
`"human"`; the existing Step 7 recommendation is preserved
bit-for-bit for human mode.

Overrides in agent mode:

- **Session reset recommendation (Step 7).** Skip the user-facing
  recommendation. Once the retrospective Exit Criteria are met
  (≥1 improvement recorded, consolidation done if due, phase
  `retrospective`, sprint `complete`), **end the turn** without
  emitting the `/clear` recommendation. The Stop / completion gate
  treats the satisfied Exit Criteria as forward progress consumed,
  and the watchdog spawns the next session for the next Sprint (or
  Integration Sprint, per `state.json`).
- **Improvement-action extraction (Step 2 / Step 3 reflection).**
  Where the reflection would normally surface "ask the user
  whether <process change> is acceptable" items, route the same
  question as `[sprint-<N>] PO_DECISION_REQUEST kind=change_request
  options=[adopt,defer,reject] recommendation=<sm-preferred>` to
  the `product-owner` teammate before recording the improvement,
  so the improvements.json entry carries the matching `dec_id`. If
  no such "ask the user" prompt exists in your current reflection,
  this rule is a no-op.
- **Assumption-flagged Sprint Review decisions feed improvements.**
  Any `PO_DECISION` from the current Sprint whose rationale begins
  with `ASSUMPTION:` (or which sets the wrapper's `assumption=true`
  flag — see `agents/product-owner.md` § Anti-loop rules) is a
  candidate improvement: record an entry pointing to the `dec_id`
  so the next refinement / planning cycle revisits the unverified
  premise.

## Steps

1. state.json → phase: "retrospective":
   ```bash
   .scrum/scripts/update-state-phase.sh retrospective
   ```
2. Reflect on Sprint: what went well, what to improve (process, communication, tooling, code quality)
3. Record ≥1 improvement → call `.scrum/scripts/append-improvement.sh --sprint <sprint-id> --description "<what to improve>"` for each item. The wrapper auto-assigns `id` (`imp-NNNN`), stamps `created_at`, sets `status: "active"`, and validates against `improvements.schema.json`. In `po_mode=agent`, when the entry derives from a `PO_DECISION_REQUEST` round-trip, pass `--dec-id dec-NNNN` to link the entry to the decision record. Direct edits to `.scrum/improvements.json` are blocked by `pre-tool-use-scrum-state-guard.sh`.
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
