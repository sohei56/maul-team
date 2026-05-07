---
name: sprint-review
description: Sprint Review ceremony — present Increment to user
disable-model-invocation: false
---

## Inputs

- state.json → phase: review
- sprint.json (Sprint data)
- backlog.json (PBI statuses)

## Outputs

- sprint-history.json → sprints[] (SprintSummary appended)
- backlog.json → new draft PBIs for every leftover (carry-over / doc mismatch / defect / change)
- state.json → phase: sprint_review
- sprint.json → status: "sprint_review"

## Preconditions

- state.json phase: "review"
- sprint.json, backlog.json exist

## Steps

1. state.json → phase: "sprint_review", sprint.json → status: "sprint_review":
   ```bash
   .scrum/scripts/update-state-phase.sh sprint_review
   .scrum/scripts/update-sprint-status.sh sprint_review
   ```
2. **Present change summary**: Sprint Goal, completed PBIs (status: done), incomplete PBIs (carry-over candidates)
3. **Launch app (mandatory)**: Detect start command (package.json/Makefile/docker-compose etc)→start→confirm running→fail→fix+retry (never skip demo)→tell user access URL/port
4. **Demo EVERY completed PBI (mandatory)**:
   a. State PBI name
   b. Show it working (navigate/call API/run command)
   c. Point out what to verify (be specific: "login form with email + password fields")
   d. Ask user to confirm→wait→next PBI. Skip only if user explicitly says no need
5. **Doc-implementation consistency**: For every completed PBI→compare docs vs code→mismatch→`add-backlog-item.sh` (status: draft). Track each new pbi-id for the Leftover Summary.
6. Report remaining backlog scope + Product Goal progress
7. Append SprintSummary to sprint-history.json: id, goal, type, pbis_completed, pbis_total, started_at, completed_at
8. Get user feedback
9. **Defect/change handling**:
   a. **NEVER fix during Sprint Review** (not even quick fixes — inspection ceremony only)
   b. Each defect/change/feedback item → `add-backlog-item.sh` (status: draft). Track each new pbi-id.
   c. "Will be prioritized in next Sprint via Backlog Refinement→Sprint Planning"
   d. After user confirms "that's all"→proceed
10. **Carry-over PBIs (mandatory)**: For every PBI in this sprint where `status != "done"` (any `in_progress_*` / `awaiting_cross_review` / `cross_review` / `escalated` / `blocked` / refined-but-not-started):
    a. Create a new draft PBI capturing the remaining work via `add-backlog-item.sh` — embed origin in description (`Carry-over from <pbi-id>: <what is left>`).
    b. Original PBI keeps its current status (immutable historical record of this Sprint).
    c. Track each new pbi-id for the Leftover Summary.

    ```bash
    .scrum/scripts/add-backlog-item.sh \
      --title "Carry-over: <orig title>" \
      --description "Continuation of <pbi-id>. Remaining: <concise scope>." \
      --ac "<criterion 1>" --ac "<criterion 2>"
    ```

11. **Leftover Summary (mandatory report)**: Print to user a single consolidated list of every draft PBI created during this Sprint Review, grouped:
    - Carry-overs (from step 10): `<new-pbi-id> ← <orig-pbi-id>: <title>`
    - Doc/impl mismatches (step 5): `<new-pbi-id>: <title>`
    - Defects / changes / feedback (step 9): `<new-pbi-id>: <title>`

    State explicitly: "These N items enter the backlog as drafts and will be re-prioritized in the next Sprint's Backlog Refinement → Sprint Planning. Nothing is dropped."
12. **Commit Sprint deliverables**: git status→stage relevant files (exclude temp/artifacts/.DS_Store)→commit:
    ```
    feat(sprint-N): <Sprint Goal>

    Completed PBIs:
    - PBI-XXX: <title>

    Co-Authored-By: <contributing developers>
    ```
    Report commit hash. Do NOT push.

Ref: FR-010, FR-011

## Exit Criteria

- SprintSummary appended to sprint-history.json
- User reviewed Increment + gave feedback
- Doc-implementation consistency checked
- Every leftover (carry-over + doc mismatch + defect/change/feedback) materialised as a draft PBI in backlog.json — none dropped
- Leftover Summary reported to user
- Sprint deliverables committed
- state.json phase: "sprint_review"
