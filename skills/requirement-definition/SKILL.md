---
name: requirement-definition
description: >
  Requirement Definition ceremony. Spawns a single Developer to elicit
  requirements from the user through natural language dialogue,
  producing a requirements document and initial Product Backlog.
disable-model-invocation: false
---

## Inputs

- `state.json` → `phase: "new"` or `"requirements_sprint"`

## Outputs

- `docs/requirements.md` — business, functional, non-functional requirements (committed to repo)
- `CLAUDE.md` — project root, ~200 lines target (project overview + cautions). Created if missing; existing→user choice
- `state.json` → new→requirements_sprint→backlog_created
- `backlog.json` — initial coarse-grained PBIs + `next_pbi_id`

## Preconditions

- state.json phase: "new" or "requirements_sprint"
- No existing requirements.md (new) or incomplete (resume)

## Roles

- **Scrum Master** — state.json transitions (steps 1, 9), Developer
  lifecycle (step 2 spawn, step 9 terminate), `backlog.json`
  initialization (step 6), user confirmation prompts (steps 7, 8a).
- **Developer (Requirements interviewer)** — user dialogue (steps 3,
  4), `docs/requirements.md` authoring (step 5), `CLAUDE.md`
  authoring when overwrite/append chosen (step 8b).

## PO Mode (po_mode: "agent")

This section only applies when `.scrum/config.json.po_mode == "agent"`.
Human-mode readers can skip it; the numbered Steps below are unchanged
and remain the canonical flow. In agent mode the SM has already spawned
the `product-owner` teammate per `agents/scrum-master.md` §
Autonomous PO Mode, and the PO has already produced
`docs/product/vision.md` (Vision / target users / Scope In · Out /
measurable release criteria) from `docs/product/brief.md` — the single
human-authored input placed at session start. The brief is the PO's
source of truth for in-scope vs out-of-scope.

The points in the numbered Steps that read as "ask the user" are
re-targeted as follows:

| Step | Phrase in human mode | Agent-mode override |
|---|---|---|
| 3, 4 | Developer engages user in natural-language dialogue; follow-up questions until clear | Developer's counterpart is the **PO teammate** via the direct `[req] INTERVIEW_QUESTION` / `[req] INTERVIEW_ANSWER` channel (the only sanctioned PO ↔ Developer direct route; see `rules/scrum-context.md` § Communication protocol). Total questions **≤ 15**, same-topic exchanges **≤ 2 round-trips**. The PO answers from `docs/product/brief.md` plus product judgment; anything not anchored in the brief is answered **"out of scope" (YAGNI)** and the rejection is appended to the `Out` section of `docs/product/vision.md`. |
| 7 | Present requirements summary + initial backlog → user confirmation | SM sends `[product] PO_DECISION_REQUEST kind=backlog_approval options=[approve,reject] recommendation=approve` with the requirements summary and the draft backlog as payload, and proceeds on `PO_DECISION`. |
| 8a | CLAUDE.md initialization 3-way choice (overwrite / append / skip) | **Not** routed to the PO. This is an operational default, not a product judgment: if `CLAUDE.md` is absent → create; if present → append. Skip is not used in agent mode. The PO is not consulted. |
| 8b | Developer writes/updates `CLAUDE.md` | Unchanged; the deterministic default from row 8a drives this step. |

Per `rules/scrum-context.md` § PO seat resolution, the SM must never
block on human input in agent mode; every PO-targeted prompt above is
resolved via `PO_DECISION_REQUEST` / `PO_DECISION` and logged through
`.scrum/scripts/append-po-decision.sh` (the PO returns `dec_id`).

## Steps

1. Bootstrap `state.json` if absent, then update phase to
   `"requirements_sprint"`. `init-state.sh` is idempotent — invoke it
   unconditionally so the sequence is deterministic on fresh and
   resumed projects alike:
   ```bash
   .scrum/scripts/init-state.sh
   .scrum/scripts/update-state-phase.sh requirements_sprint
   ```
2. Spawn 1 Developer for requirements interview
3. Developer engages user in natural language:
   - Business: problem, users, goals
   - Functional: features, key workflows
   - Non-functional: performance, security, scalability, platform constraints
   - Constraints: tech preferences, limitations
4. Unclear/incomplete→follow-up questions. Do not proceed until sufficiently clear
5. Produce `docs/requirements.md` with structured sections (create `docs/` dir if missing)
6. SM creates `backlog.json` with coarse PBIs (status: "draft"). Use
   the wrappers — direct edits to `.scrum/backlog.json` are blocked.
   `init-backlog.sh` seeds the file (`items=[]`, `next_pbi_id=1`,
   `product_goal=<text>`); each `add-backlog-item.sh` allocates the
   next `pbi-NNN` id and appends one coarse PBI in `draft` status:
   ```bash
   .scrum/scripts/init-backlog.sh --product-goal "<product goal text>"
   .scrum/scripts/add-backlog-item.sh \
     --title "<PBI title>" \
     --description "<one-line description>" \
     --ac "<acceptance criterion 1>" \
     --ac "<acceptance criterion 2>"
   # ...repeat per coarse PBI
   ```
7. Present requirements summary + initial backlog→user confirmation
8. **CLAUDE.md initialization** (project root):
   - Exists→ask user: overwrite / append / skip
   - Not exists or user chose overwrite/append→Developer writes/updates `CLAUDE.md`:
     - **Project overview**: purpose, users, key features (from requirements.md)
     - **Cautions level only**: key constraints, security concerns, critical conventions. No detailed architecture/directory structure (Integration Sprint regenerates that)
     - Target ~200 lines (目安). Exceeded→warn user, do not block
9. Update `state.json` → `phase: "backlog_created"`:
   ```bash
   .scrum/scripts/update-state-phase.sh backlog_created
   ```
   Then terminate Requirement Definition Developer.

Ref: FR-002

## Exit Criteria

- `requirements.md` exists (business + functional + non-functional covered)
- `backlog.json` exists (≥1 draft PBI)
- `CLAUDE.md` exists at project root (created or user-confirmed skip/append)
- state.json phase: "backlog_created"
- User confirmed
- po_mode=agent: `docs/product/vision.md` exists (Vision / target users / Scope In · Out / measurable release criteria)
