---
name: requirement-definition
description: >
  Requirement Definition ceremony. Spawns a single requirements-analyst
  to elicit requirements through natural-language dialogue and mandatory
  benchmark web-search research, producing a requirements document, a
  benchmark findings document, and the initial Product Backlog.
disable-model-invocation: false
---

## Inputs

- `state.json` → `phase: "new"` or `"requirements_sprint"`
- `docs/product/brief.md` — the human-authored product brief, co-authored
  at launch in **both** human and agent modes (via the `create-brief` skill:
  the `scrum-start.sh` pre-flight on a new project, or `--brief <file>` in
  autonomous mode). It is the **anchor** for the interview and the source of
  truth for in-scope vs out-of-scope. Requirements must realize the brief;
  where they conflict, exactly one side is amended (see step 6). On the rare
  path where no brief exists (user skipped the pre-flight, or a pre-brief
  resumed project), the ceremony proceeds from the interview alone and the
  brief is treated as absent.

## Outputs

- `docs/requirements.md` — business, functional, non-functional requirements (committed to repo)
- `docs/product/brief.md` — **possibly amended** during step 6 reconciliation when the interview reveals the brief was wrong/stale (committed to repo)
- `docs/requirements-benchmark.md` — benchmark findings from similar products / prior art (source URLs + per-item `adopt`/`adapt`/`reject` disposition), gathered via mandatory web search (committed to repo)
- `CLAUDE.md` — project root, ~200 lines target (project overview + cautions). Created if missing; existing→user choice
- `state.json` → new→requirements_sprint→backlog_created
- `backlog.json` — initial coarse-grained PBIs + `next_pbi_id`

## Preconditions

- state.json phase: "new" or "requirements_sprint"
- No existing requirements.md (new) or incomplete (resume)

## Roles

- **Scrum Master** — state.json transitions (steps 1, 10),
  requirements-analyst lifecycle (step 2 spawn, step 10 terminate),
  `backlog.json` initialization (step 7), user confirmation prompts
  (steps 5, 8, 9a).
- **Requirements Analyst** (`../../agents/requirements-analyst.md`) — reads
  `docs/product/brief.md` and anchors the interview to it (step 3), user
  dialogue (steps 3, 4), mandatory benchmark web-search research (step
  5), `docs/requirements.md` + `docs/requirements-benchmark.md`
  authoring (steps 5, 6), brief ↔ requirements reconciliation incl.
  amending `docs/product/brief.md` when the PO seat so decides (step 6),
  `CLAUDE.md` authoring when overwrite/append chosen (step 9b). Spawned
  solely for this ceremony; not the Sprint PBI-pipeline Developer.

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, every PO-approval prompt
in the numbered Steps below re-targets to the `product-owner` teammate
per `../../rules/scrum-context.md` § PO seat resolution; the ceremony shape
is unchanged. Skill-specific context: the SM has already spawned the
`product-owner` teammate per `../../agents/scrum-master.md` § Autonomous PO
Mode, and the PO has already produced `docs/product/vision.md` (Vision
/ target users / Scope In · Out / measurable release criteria) from
`docs/product/brief.md` — the single human-authored input placed at
session start. The brief is the PO's source of truth for in-scope vs
out-of-scope.

The points in the numbered Steps that read as "ask the user" are
re-targeted as follows:

| Step | Phrase in human mode | Agent-mode override |
|---|---|---|
| 3, 4 | Requirements Analyst engages user in natural-language dialogue; follow-up questions until clear | The Analyst's counterpart is the **PO teammate** via the direct `[req] INTERVIEW_QUESTION` / `[req] INTERVIEW_ANSWER` channel (the only sanctioned PO ↔ requirements-analyst direct route; see `../../rules/scrum-context.md` § Communication protocol). Total questions **≤ 15**, same-topic exchanges **≤ 2 round-trips**. The PO answers from `docs/product/brief.md` plus product judgment; anything not anchored in the brief is answered **"out of scope" (YAGNI)** and the rejection is appended to the `Out` section of `docs/product/vision.md`. |
| 5 | Present benchmark findings → user picks `adopt`/`adapt`/`reject` per item | The Analyst still runs the mandatory web search (`WebSearch` is not gated by mode). SM sends `[product] PO_DECISION_REQUEST kind=spec_clarification options=[adopt,adapt,reject] recommendation=<per-item>` with `docs/requirements-benchmark.md` as payload; the PO returns the per-item dispositions (grounded in `brief.md`) and the Analyst records them. Proceeds on `PO_DECISION`. |
| 8 | Present requirements summary + initial backlog → user confirmation | SM sends `[product] PO_DECISION_REQUEST kind=backlog_approval options=[approve,reject] recommendation=approve` with the requirements summary and the draft backlog as payload, and proceeds on `PO_DECISION`. |
| 9a | CLAUDE.md initialization 3-way choice (overwrite / append / skip) | **Not** routed to the PO. This is an operational default, not a product judgment: if `CLAUDE.md` is absent → create; if present → append. Skip is not used in agent mode. The PO is not consulted. |
| 9b | Requirements Analyst writes/updates `CLAUDE.md` | Unchanged; the deterministic default from row 9a drives this step. |

## Steps

1. Bootstrap `state.json` if absent, then update phase to
   `"requirements_sprint"`. `init-state.sh` is idempotent — invoke it
   unconditionally so the sequence is deterministic on fresh and
   resumed projects alike:
   ```bash
   .scrum/scripts/init-state.sh
   .scrum/scripts/update-state-phase.sh requirements_sprint
   ```
2. Spawn 1 `requirements-analyst` for the requirements interview
3. Requirements Analyst **reads `docs/product/brief.md` first** (when
   present) and anchors the interview to it, then engages the user in
   natural language to deepen and make each brief item testable:
   - Business: problem, users, goals
   - Functional: features, key workflows
   - Non-functional: performance, security, scalability, platform constraints
   - Constraints: tech preferences, limitations
4. Unclear/incomplete→follow-up questions. Do not proceed until sufficiently clear
5. **Benchmark research (mandatory web search — before formulating
   requirements alone).** Before the Analyst formulates functional /
   non-functional requirements from its own knowledge, it researches
   similar products / projects / prior art. **Its internal knowledge is
   not a substitute for live search.**
   - Run **≥3 distinct `WebSearch` queries** derived from the problem
     domain, target users, and rough feature areas from steps 3–4;
     follow with `WebFetch` on the most relevant sources.
   - Extract, per source: design philosophy, notable features,
     requirement / spec ideas, tech-stack choices, and common pitfalls
     to avoid.
   - Produce `docs/requirements-benchmark.md` (create `docs/` if
     missing): one entry per idea with `source URL`, `category ∈
     {philosophy, feature, requirement, spec, tech-stack, pitfall}`, a
     one-line summary, and a `disposition` field defaulting to
     `proposed`.
   - **Present the findings to the user** and let the user decide, per
     item, `adopt` / `adapt` / `reject`. Record the chosen disposition
     (and any adaptation note) back into
     `docs/requirements-benchmark.md`. (agent mode: routed to the PO —
     see § PO Mode row 5.)
   - **WebSearch unavailable → harness incident, not a fallback.** If
     `WebSearch` is not in the Analyst's tool surface, or it fails
     repeatedly at the harness level (not a "no results" content
     outcome), **stop**. Do NOT substitute internal knowledge. Report
     the incident: `po_mode=human` → surface to the user and wait;
     `po_mode=agent` → append to `.scrum/po/attention.md` and stop.
     (Mirrors `../../rules/scrum-context.md` § Agent tool unavailability.)
6. Produce `docs/requirements.md` with structured sections (create
   `docs/` dir if missing). Functional / non-functional requirements
   that originate from an adopted benchmark item carry a provenance ref
   back to `docs/requirements-benchmark.md`.
   - **Brief ↔ requirements reconciliation (mandatory).** Before
     finalizing, cross-check the requirements against
     `docs/product/brief.md`. Where a requirement contradicts the brief
     (scope, goal, constraint, priority, or a success metric), the
     Analyst **surfaces the conflict and resolves it by amending exactly
     one side** — never let `requirements.md` silently diverge from the
     brief:
     - **Amend the brief** (`Edit` `docs/product/brief.md`) when the
       interview revealed the brief was wrong, stale, or incomplete.
     - **Amend the requirement** when the brief is authoritative and the
       requirement over-reached (drop it as out-of-scope, or align it).
     - The choice of which side to change is a **PO-seat decision**:
       `po_mode=human` → the Analyst asks the user; `po_mode=agent` → SM
       routes `[product] PO_DECISION_REQUEST kind=spec_clarification`
       naming the conflict and a recommendation, and the fix follows the
       `PO_DECISION` (logged via `append-po-decision.sh`).
     - After reconciliation, `brief.md` and `requirements.md` must be
       mutually consistent. Note any brief edits in the ceremony summary
       (step 8) so the human/PO sees what the brief now says.
7. SM creates `backlog.json` with coarse PBIs (status: "draft"). Use
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
8. Present requirements summary + initial backlog→user confirmation
9. **CLAUDE.md initialization** (project root):
   - Exists→ask user: overwrite / append / skip
   - Not exists or user chose overwrite/append→Requirements Analyst writes/updates `CLAUDE.md`:
     - **Project overview**: purpose, users, key features (from requirements.md)
     - **Cautions level only**: key constraints, security concerns, critical conventions. No detailed architecture/directory structure (Integration Sprint regenerates that)
     - Target ~200 lines (目安). Exceeded→warn user, do not block
10. Update `state.json` → `phase: "backlog_created"`:
   ```bash
   .scrum/scripts/update-state-phase.sh backlog_created
   ```
   Then terminate the Requirement Definition `requirements-analyst`.

Ref: FR-002

## Exit Criteria

- `requirements.md` exists (business + functional + non-functional covered)
- `docs/requirements-benchmark.md` exists (≥1 benchmark item from live web search, each with a source URL and a user/PO disposition) — unless a WebSearch harness incident was surfaced and is unresolved
- `backlog.json` exists (≥1 draft PBI)
- `CLAUDE.md` exists at project root (created or user-confirmed skip/append)
- state.json phase: "backlog_created"
- User confirmed
- po_mode=agent: `docs/product/vision.md` exists (Vision / target users / Scope In · Out / measurable release criteria)
