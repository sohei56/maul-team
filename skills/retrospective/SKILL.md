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
to the user" line cannot be acted on by anyone in-session. This
section is a no-op when `po_mode` is absent or `"human"`; the
existing Step 7 recommendation is preserved bit-for-bit for human
mode.

Overrides in agent mode:

- **Sprint-continuation handshake (replaces Step 7).** Skip the
  user-facing `/clear` recommendation. The retrospective is **not**
  the end of the workflow — leaving `state.json.phase` at
  `retrospective` is a dead end: nothing advances it, and the
  autonomy watchdog reads an unchanged phase as `no_progress` and
  trips the failure circuit breaker. After the retrospective Exit
  Criteria are met, the SM must obtain a Product-Owner
  **`sprint_continuation`** decision and advance the phase itself
  (Step 8 below). The PO — not the SM and not the watchdog — owns
  the call of whether another Sprint is warranted, because it turns
  on Product-Goal completion. Only once the phase has advanced to
  `backlog_created`, `integration_sprint`, or `complete` does the
  SM end the turn.
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

### 8. Sprint-continuation handshake (po_mode: "agent" only)

**Human mode skips this step** (Step 7's `/clear` recommendation
applies instead; the user drives the next Sprint manually, and
`sprint-planning` accepts `phase: retrospective` as its entry).

In agent mode, once Steps 1–6 are complete, the SM asks the PO what
comes next and advances the workflow:

1. Send the Product Owner teammate:

   ```
   [sprint-<N>] PO_DECISION_REQUEST kind=sprint_continuation
   options=[next_sprint,integration_sprint,complete]
   recommendation=<sm-preferred>
   payload: product_goal_status=<met|not_met>,
   refined_pbis_remaining=<count>, sprint=<N>/<max_sprints>
   ```

   The `recommendation` follows the same precedence the PO uses
   (see `agents/product-owner.md` § Sprint continuation): default
   `next_sprint` while feature PBIs remain and Sprints are left.

2. On `PO_DECISION ... decision=choice:<label> dec_id=dec-NNNN`,
   advance `state.json.phase` to match — this is the step that
   unblocks the autonomy watchdog:

   | PO decision | Phase transition |
   |---|---|
   | `choice:next_sprint` | `.scrum/scripts/update-state-phase.sh backlog_created` |
   | `choice:integration_sprint` | `.scrum/scripts/update-state-phase.sh integration_sprint` |
   | `choice:complete` | `.scrum/scripts/update-state-phase.sh complete` |

   The decision is already audit-logged by the PO via
   `append-po-decision.sh`; the SM only performs the phase write.

3. End the turn. The watchdog's completion-gate treats a
   `backlog_created` phase that follows a recorded Sprint
   (sprint-history non-empty) as a recycle checkpoint, so the next
   session starts fresh on Sprint Planning. `integration_sprint`
   and `complete` are likewise clean stop points.

**Do not** end the turn while `phase` is still `retrospective` in
agent mode — that is the dead end this step exists to prevent.

## Exit Criteria

- ≥1 improvement recorded (all fields set)
- If consolidation due→archived + last_consolidation_sprint updated
- sprint.json status: "complete"
- **Human mode:** state.json phase: "retrospective"; session reset
  recommended to user.
- **Agent mode (po_mode: "agent"):** a `sprint_continuation`
  PO decision is recorded and state.json phase has advanced to
  `backlog_created`, `integration_sprint`, or `complete` (never left
  at `retrospective`).
