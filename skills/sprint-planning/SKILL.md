---
name: sprint-planning
description: Sprint Planning ceremony — select PBIs, assign developers, create Sprint
disable-model-invocation: false
---

## Inputs

- `state.json` → phase: backlog_created | retrospective
- `backlog.json` → PBIs with status: refined

## Outputs

- `sprint.json`: id, goal, type: development, status: planning
- `backlog.json` → items[].sprint_id, implementer_id assigned (per-PBI review runs Developer-side inside pbi-pipeline as the Integrity stage; Sprint end adds only the audit-only `cross-review` ceremony). **Sprint PBI membership is derived from these `sprint_id` assignments** — `sprint.json` no longer carries a `pbi_ids` array (OD-4 single-source).
- Oversized PBIs split into children (parent_pbi_id set)
- `state.json` → phase: sprint_planning

## Preconditions

- state.json phase: "backlog_created" or "retrospective"
- backlog.json has ≥1 refined PBI
- No active Sprint in progress

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, every PO-approval prompt
in the numbered Steps below re-targets to the `product-owner` teammate
per `rules/scrum-context.md` § PO seat resolution; the ceremony shape
is unchanged. The "ask the user" points are re-targeted as follows:

| Step | Phrase in human mode | Agent-mode override (kind, scope, defaults) |
|---|---|---|
| 1 | Uncommitted-file 3-way choice (commit now / stash / proceed anyway) | `kind=git_dirty`, `scope=sprint-N`, `options=[commit_now,stash,proceed_anyway]`. The full `git status` file list is included as payload. **PO default policy:** if every changed path lies inside a deliverable directory → `choice:commit_now`; if only temporary files (build/, dist/, *.tmp, etc.) → `choice:proceed_anyway`. Mixed cases fall back to `commit_now`. |
| 3 | Propose Sprint Goal → user approval | `kind=sprint_goal_approval`, `scope=sprint-N`, `options=[approve,reject]`. **Reject is capped at 2 rounds.** On the third request the PO must reply `decision=approve` with the verbatim Sprint Goal in the `rationale` (`PROPOSED_GOAL: <text>` — see `agents/product-owner.md` § Anti-loop rules); the SM **adopts that goal verbatim** and ends the ping-pong. |
| 5 | Oversized PBI split → user confirmation | `kind=pbi_split`, `scope=pbi-NNN`, `options=[approve,reject]`. The parent PBI id, the child PBI breakdown, and the split rationale are payload. On `reject` the SM keeps the parent and reports the un-split risk in the Sprint summary. |
| 12 | Present Sprint summary + 6-option menu → wait for user selection | The same summary is sent as `kind=scope_change` if it mutates Sprint membership, otherwise as `kind=sprint_goal_approval` for re-approval. `options=[choice:start_sprint, choice:adjust_goal, choice:change_pbis, choice:reassign_devs, choice:view_backlog, choice:other]`. PO replies `decision=choice:<label>`. **Default recommendation: `choice:start_sprint`.** Any non-start choice loops the SM back to the corresponding step (3 / 4-5 / 7) and re-asks. |

Step 13 ("On Start Sprint") fires automatically when the Step 12
decision is `choice:start_sprint`. No additional PO request is needed.

## Steps

1. **Uncommitted file check (mandatory)**: Run `git status`→uncommitted changes exist→warn user with file list→user must choose: commit now, stash, or proceed anyway→resolve before continuing
2. **Transition state**: state.json → phase: "sprint_planning" (TUI reflects immediately):
   ```bash
   .scrum/scripts/update-state-phase.sh sprint_planning
   ```
3. Propose Sprint Goal→user approval before proceeding
4. Select refined PBIs. Avoid dependent PBIs in same Sprint (FR-008)
5. **Evaluate + split oversized PBIs**: Too large→create child PBIs (status: "refined", parent_pbi_id set, split acceptance_criteria, copy design_doc_paths/ux_change)→remove parent from Sprint→replace with children→user confirmation
6. Compute target developer count: `min(selected PBI count, 6)`. **1 Developer = 1 PBI (hard constraint).** >6 PBIs→select 6, defer rest. This number is **not persisted** in `sprint.json`; it is enforced by spawn-teammates writing exactly that many entries to `developers[]`.
7. Assign implementers: format `dev-001-s{N}`, `dev-002-s{N}` (zero-pad mandatory, -s{N} suffix mandatory, no short forms). No reviewer assignment — the per-PBI 5-aspect review runs inside pbi-pipeline (Integrity stage); Sprint-end cross-review is an audit-only SM ceremony (FR-009 Layer 2)
8. **Roll over the previous Sprint, then create sprint.json + update
   state.current_sprint_id (atomic pair).**

   On the **second and later** Sprints a completed `sprint.json` from
   the prior Sprint is still on disk. `init-sprint.sh` refuses while it
   exists and `freeze-sprint-base.sh` refuses while its `base_sha` is
   frozen — so you **must** archive-and-clear it first via
   `rollover-sprint.sh`. The wrapper archives the completed Sprint to
   `sprint-history.json` and removes `sprint.json`; it is an idempotent
   no-op on the **first** Sprint (no `sprint.json` yet), so always run
   it before `init-sprint.sh`:
   ```bash
   .scrum/scripts/rollover-sprint.sh
   ```
   `rollover-sprint.sh` refuses unless the prior Sprint is
   `status: complete`. If it refuses, the previous Sprint never reached
   a terminal state — stop and resolve that (do **not** force it); a
   non-complete prior Sprint is a real signal, not a rollover input.

   Then `init-sprint.sh` creates `.scrum/sprint.json` at
   `status: "planning"` AND writes `state.current_sprint_id` in the
   same invocation. Keeping the two in sync at Sprint start prevents
   the recurring `current_sprint_id` lag that `completion-gate.sh`
   catches mid-Sprint:
   ```bash
   .scrum/scripts/init-sprint.sh "$SPRINT_ID" --goal "$GOAL" --type development
   ```
   If you skip this wrapper or only create sprint.json by other means,
   `state.current_sprint_id` will still point at the previous Sprint
   and downstream phase transitions will block.

   > The new Sprint's base is captured later by `spawn-teammates`
   > (`freeze-sprint-base.sh`, once per Sprint). Because `rollover-sprint.sh`
   > cleared the prior `sprint.json`, that call now records
   > `base_sha = current main HEAD` — which includes the prior Sprint's
   > merged work — instead of refusing on a stale frozen base.

9. Update backlog.json: sprint_id, implementer_id. For each PBI in
   the Sprint:
   ```bash
   .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" sprint_id "$SPRINT_ID"
   .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" implementer_id "$DEV_ID"
   ```

10. **Catalog Target Assignment** (PBI Pipeline parallel-safety):

    For each PBI in the sprint:
    1. Read PBI description + requirements to identify catalog spec
       paths it will touch (entries enabled in catalog-config.json).
    2. Record in backlog.json items[].catalog_targets[]:
       ```bash
       .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" catalog_targets "$TARGETS_JSON"
       ```
       where `$TARGETS_JSON` is a JSON-encoded array, e.g.
       `'["docs/design/specs/foo.md","docs/design/specs/bar.md"]'`.
    3. **Conflict check**: For PBIs with overlapping catalog_targets in
       this sprint, ensure they are NOT assigned to different
       developers in parallel. Either sequence them on one developer,
       or split the PBI to remove overlap.
    4. If overlap unavoidable → note in sprint.json that runtime flock
       will arbitrate (Layer 2 of catalog-contention defense).

> **Note (worktree governance).** Per-PBI worktrees give physical
> isolation, so two PBIs touching the same source file no longer
> corrupt each other at write time. Conflicts surface during
> `pbi-merge` and the assigned Developer rebases. Pre-separation is
> still required for catalog files (see `catalog-contention.md`).

11. **Source-file overlap pre-flight** (merge-conflict prevention):

    Worktree isolation prevents *write-time* corruption but does not
    prevent *merge-time* conflicts. Three retrospective patterns from
    target projects produced large rebase-conflict blasts and **must**
    be screened at planning time:

    - **Epic + leaf overlap.** An "Epic" PBI that touches many files
      across modules, scheduled alongside individual leaf PBIs in the
      same module. Observed in a target project: an 11-file conflict
      across 5 PBIs in a single Sprint because the Epic and leaves
      ran in parallel. **Rule:** if a PBI's predicted footprint
      exceeds ~5 source files OR explicitly says "all strategies" /
      "全 strategies" / "cross-module", schedule it as a single-PBI
      Sprint (or merge it last after all leaves).
    - **Rename / module-shuffle PBIs in parallel.** Observed in a
      target project: two rename PBIs in the same Sprint hit 11
      overlapping files. **Rule:** rename / file-move /
      module-restructure PBIs are serial — at most one per Sprint, or
      chained on a single developer with `depends_on_pbi_ids` set.
    - **Shared design-spec edits beyond catalog_targets.** Observed
      in a target project: three PBIs in the same Sprint all touched
      the same spec section. The `catalog_targets` check in step 10 covers spec
      *files*, not section-level overlap. **Rule:** if 3+ PBIs in the
      Sprint touch the same `docs/design/specs/<file>.md`, carve out
      a separate "spec consolidation" PBI to be merged first and
      have the others rebase onto it.

    Procedure for SM:
    1. For each PBI, sketch the **predicted source paths** from
       description + acceptance_criteria + (if available) similar
       prior PBIs' `paths_touched`.
    2. Build a path-overlap matrix across PBIs in the Sprint.
    3. For any two PBIs sharing ≥1 predicted path AND assigned to
       different developers, apply one of the three rules above.
    4. Record the decision visibly: either re-assign to single
       developer with `depends_on_pbi_ids`, or split into pre/post
       PBIs, or remove the lower-priority PBI from the Sprint and
       defer.

    This is the planning-time defense. Runtime defense (per-PBI
    worktree + `merge-pbi.sh` 3-strike escalation) still applies, but
    is far more expensive to recover from once it fires.

    **Opus override for the path overlap analysis (mandatory).** The
    same failure mode has recurred across 4 Sprints in 2 target
    projects even after the three rules above were pinned into this
    SKILL. The SM
    main loop runs on Sonnet (see `agents/scrum-master.md`); pinned
    text alone has not been sufficient. Delegate the overlap analysis
    to an Opus-backed sub-agent via the `Agent` tool — do NOT compute
    the matrix in the SM main loop:

    ```
    Agent({
      subagent_type: "general-purpose",
      model: "opus",
      description: "Sprint path-overlap pre-flight",
      prompt: <<<EOF
        Analyse merge-conflict risk for this Sprint's PBI selection.

        Inputs (paste verbatim from .scrum/backlog.json + history):
        - Sprint PBIs: id, title, description, acceptance_criteria
        - For each PBI, similar prior PBIs' paths_touched if available
          (jq from completed PBIs in backlog.json + .scrum/pbi/<id>/state.json)
        - Catalog spec targets per PBI (items[].catalog_targets)

        Steps:
        1. Sketch predicted source paths for each PBI (file-level, not directory).
        2. Build a path-overlap matrix; flag any pair with >=1 predicted
           path overlap AND different implementer_id.
        3. Match each flagged pair against the three rules:
           (a) Epic + leaf: PBI predicted footprint >5 files OR
               description mentions "all strategies" / "全 strategies" /
               "cross-module"
           (b) Rename / module-shuffle: rename / file-move / module-restructure
           (c) Shared design-spec: >=3 PBIs touch the same
               docs/design/specs/<file>.md section
        4. For each match, recommend: serialize-on-one-dev / split into pre+post /
           defer lower-priority. Cite the rule.

        Output: JSON
          {
            "predicted_paths": { "<pbi-id>": ["path1", ...], ... },
            "overlap_pairs": [
              { "a": "<pbi>", "b": "<pbi>", "shared": ["..."],
                "rule": "epic|rename|shared-spec",
                "recommendation": "...", "reason": "..." }
            ],
            "safe": ["<pbi>", ...]
          }
      EOF
    })
    ```

    SM main loop reads the JSON and applies the recommendations
    (re-assignment / split / defer) via the wrappers in Step 5/6/7.
    The Opus sub-agent does NOT call wrappers itself — it is read-only
    analysis. Record the decision visibly in the Sprint summary so the
    PO (po_mode=agent) or user can override at Step 12.

11.5. **Merge regression gate check**: read
    `.scrum/config.json.merge_regression.command`. If absent / empty /
    null, every per-PBI merge this Sprint will land with the
    regression gate skipped (`merge-pbi.sh` prints a WARN nobody acts
    on — a target project shipped a broken test suite to main this
    way across multiple Sprints). Include a visible WARN line in the
    Step 12 Sprint summary recommending a command (e.g. the project's
    test suite). Human mode: the user decides whether to configure it
    before starting. Agent mode: proceed (do not block planning);
    `merge-pbi.sh` will surface the skipped gate to
    `.scrum/po/attention.md` once per Sprint.

12. **Present Sprint summary + options**:
    - 1. Start Sprint
    - 2. Adjust Sprint Goal
    - 3. Change PBI selection
    - 4. Re-assign developers
    - 5. View backlog
    - 6. Other
    → Wait for user selection
13. **On "Start Sprint"**: Enable catalog-config.json entries→run
    scaffold-design-spec→**commit the scaffold to main**→spawn-teammates.

    The commit step is mandatory and ordered BEFORE spawn-teammates:
    `spawn-teammates` Step 0 freezes `sprint.base_sha` from committed
    HEAD, and every PBI worktree forks from that commit. An
    uncommitted stub or catalog-config enable is invisible to all
    worktrees — a target project shipped a PBI with no design spec
    exactly this way. `freeze-sprint-base.sh` machine-enforces the
    ordering (refuses while `docs/design/` has uncommitted changes):

    ```bash
    git add docs/design/
    git commit -m "chore(sprint): enable catalog entries + scaffold design-spec stubs"
    ```

Ref: FR-004, FR-005, FR-006, FR-007, FR-008

## Exit Criteria

- sprint.json exists (status: planning, all fields set)
- All PBIs: implementer_id assigned
- 1 Developer = 1 PBI (1:1)
- state.json phase: sprint_planning
