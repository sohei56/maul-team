# Data Model: Maul Team

State persists as JSON files in `.scrum/`, one per concern. Owners write
through `.scrum/scripts/*.sh` wrappers (raw `Write`/`Edit` is blocked by
`hooks/pre-tool-use-scrum-state-guard.sh`); readers consult the SSOT
schemas under `docs/contracts/scrum-state/`. The wrappers are deployed
from this repo's `scripts/scrum/` source by `setup-user.sh`.

---

## Entity: ProjectState

**File**: `.scrum/state.json`
**Owner**: Scrum Master (read/write)
**Readers**: scrum-start.sh (on resume), Textual dashboard app, statusline.sh

| Field | Type | Description |
|-------|------|-------------|
| `product_goal` | string | User-defined desired future state of the product |
| `current_sprint_id` | string \| null | ID of the active Sprint, null if none |
| `phase` | enum | Current workflow phase (see State Transitions) |
| `created_at` | ISO 8601 string | Project creation timestamp |
| `updated_at` | ISO 8601 string | Last state change timestamp |

### State Transitions: `phase`

```
new -> requirements_sprint -> backlog_created -> sprint_planning
  -> pbi_pipeline_active -> review -> sprint_review -> retrospective
retrospective      -> backlog_created (next Sprint) -> sprint_planning
retrospective      -> integration_sprint -> uat_release -> complete
integration_sprint -> backlog_created (defect-fix loop)
uat_release        -> backlog_created (UAT defect loop)
```

Valid phases:
- `new` — project just created, no work started. On a new project the
  `scrum-start.sh` launcher co-authors `docs/product/brief.md`
  (create-brief pre-flight, both modes) before Requirement Definition;
  the brief is a pre-ceremony input, not a distinct phase.
- `requirements_sprint` — Requirement Definition in progress (anchored on
  `docs/product/brief.md`)
- `backlog_created` — initial Product Backlog created, ready for first Development Sprint
- `sprint_planning` — Sprint Planning in progress (refining PBIs, assigning teammates)
- `pbi_pipeline_active` — Developers driving per-PBI `pbi-pipeline` skill (replaces former `design` + `implementation` phases). Each Developer's PBI internal state lives at `.scrum/pbi/<pbi-id>/state.json` (see `PbiPipelineState` below).
- `review` — Sprint-end cross-review phase (`cross-review` skill)
- `sprint_review` — Sprint Review with user
- `retrospective` — Sprint Retrospective
- `integration_sprint` — Integration Tests in progress: design-driven
  systematic testing (boundary values, flow-branch and pattern-branch
  coverage, external-interface stubs) via the `integration-tests`
  skill. On passing tests the Scrum Master advances to `uat_release`;
  on failures it returns to `backlog_created` (defect-fix loop).
- `uat_release` — UAT & Release in progress: user-story-driven UAT
  and the go/no-go release decision via the `uat-release` skill.
  Entered only after `integration_sprint` tests pass. Advances to
  `complete` on a release go, or back to `backlog_created` when UAT
  surfaces defects.
- `complete` — product released

---

## Entity: ProductBacklog

**File**: `.scrum/backlog.json`
**Owner**: Scrum Master (read/write)
**Readers**: Developer teammates (filtered by assignment), Textual dashboard app, statusline.sh

| Field | Type | Description |
|-------|------|-------------|
| `product_goal` | string | Duplicated from state for self-contained reads |
| `items` | PBI[] | Ordered list of Product Backlog Items |
| `next_pbi_id` | integer | Auto-increment counter for PBI IDs |

---

## Entity: PBI (Product Backlog Item)

**Embedded in**: `backlog.json` -> `items[]`

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (e.g., `"pbi-001"`) |
| `title` | string | Short description (e.g., "User Management") |
| `description` | string | Full description; coarse-grained when `draft`, detailed when `refined` |
| `acceptance_criteria` | string[] | Testable conditions that define when the PBI is complete. Empty array when `draft`, non-empty when `refined` |
| `status` | enum | Lifecycle state (see below) |
| `priority` | integer | Order in backlog (1 = highest) |
| `sprint_id` | string \| null | Sprint this PBI is assigned to, null if in backlog |
| `implementer_id` | string \| null | Developer teammate assigned to implement |
| `design_doc_paths` | string[] | Paths to design documents relative to project root (catalog specs in `docs/design/specs/`, plus PBI working design at `.scrum/pbi/<pbi-id>/design/design.md`) |
| `review_doc_path` | string \| null | Path to review results relative to project root |
| `catalog_targets` | string[] | Catalog spec paths the PBI may touch. Recorded by `sprint-planning` skill; used to prevent parallel write contention (Layer 1 of `catalog-contention` defense). |
| `depends_on_pbi_ids` | string[] | IDs of PBIs that must be completed before this one (used by FR-008) |
| `ux_change` | boolean | Whether this PBI involves UX changes (determines live demo in FR-010) |
| `parent_pbi_id` | string \| null | ID of the coarse-grained PBI this was refined from |
| `kind` | enum (`code` \| `docs`) | Pipeline branch selector (default `code`). Set during `backlog-refinement` (the Opus 3-axis OR rule is canonical in `skills/backlog-refinement/SKILL.md`). For how `kind=docs` reshapes the pipeline, see the **kind=docs override** subsection below (and `skills/pbi-pipeline/SKILL.md` § Stages). |
| `created_at` | ISO 8601 string | Creation timestamp |
| `updated_at` | ISO 8601 string | Last update timestamp |
| `merged_sha` | string \| absent | Mirror of `pbi/<id>/state.json.merged_sha`; written by `mark-pbi-merged.sh` on the per-PBI merge into `main` |
| `merged_at` | ISO 8601 string \| absent | Mirror of `pbi/<id>/state.json.merged_at`; written by `mark-pbi-merged.sh` |

### State Transitions: `status` (12-value enum, actor-split)

`status` is the sole SSOT for PBI lifecycle. Two actors own disjoint
slices of the enum:

```
SM-managed (7):  draft, refined, blocked, awaiting_cross_review,
                 cross_review, escalated, done
Dev-managed (5): in_progress_design, in_progress_impl,
                 in_progress_pbi_review, in_progress_ut_run,
                 in_progress_merge
```

ASCII transition graph:

```
[SM]  draft → refined
                ↓ (Sprint Planning assigns Developer)
[Dev] in_progress_design
        ↓ design pass (codex-design-reviewer)
[Dev] in_progress_impl ←──────────┐
        ↓                          │ FAIL
[Dev] in_progress_pbi_review ──────┤  (codex-impl-reviewer + codex-ut-reviewer)
        ↓ PASS                     │
[Dev] in_progress_ut_run ──────────┘ FAIL  (real test execution + coverage gate)
        ↓ PASS
[Dev] in_progress_merge            (Developer signals "ready for merge")
        ↓ SM picks up, runs merge-pbi.sh
        ↓ merge PASS
[SM]  awaiting_cross_review        (merged into main, queued until Sprint end)
        ↓ Sprint-end SM invokes cross-review skill
[SM]  cross_review ── FAIL → [Dev] in_progress_impl  (Developer fixes on top of merged code)
        ↓ PASS
[SM]  done

  any [Dev] in_progress_* → [SM] escalated  (Developer trips a termination gate)
  in_progress_merge       → [SM] escalated  (SM merge failed)
  [SM] escalated → [Dev] in_progress_design  (SM retry; round counters reset)
  [SM] escalated → [SM] blocked              (SM hold / human-escalate)
  [SM] blocked   → [Dev] in_progress_design  (external blocker resolved)
```

**kind=docs override:** when `items[].kind == "docs"`, the pipeline
skips `in_progress_design` and `in_progress_ut_run` entirely:

```
[SM]  refined
        ↓ (Sprint Planning assigns Developer)
[Dev] in_progress_impl  ←──────────┐
        ↓                           │ FAIL
[Dev] in_progress_pbi_review ───────┘   (codex-impl-reviewer only)
        ↓ PASS
[Dev] in_progress_merge             (mark-pbi-ready-to-merge enforces
                                      paths_touched ⊆ **/*.md; violation
                                      → escalated(kind_mismatch))
        ↓ (per-PBI merge)
[SM]  awaiting_cross_review → cross_review → done
```

The two retry paths (`escalated → in_progress_design` retry, `blocked
→ in_progress_design` resume) for kind=docs PBIs go to
`in_progress_impl` instead, since design is never the failed stage.

`pbi-state.json` `*_status` carries the value **`skipped`** on the
stages a kind=docs PBI does not run: `design_status` and
`coverage_status`. `ut_status` stays **`pending`** (the UT author/run
is skipped, not the status value — `begin-impl-round.sh` resets
`ut_status` to `pending` every impl round regardless of `kind`).
`impl_status` retains the kind=code enum
(pending/in_review/fail/pass) since impl is the one stage that
always runs.

State descriptions:

- `draft` — coarse-grained (e.g., "User Management"). Created during initial backlog creation.
- `refined` — implementation-ready (one function, screen, API, or platform component). Refined during Sprint Planning. `acceptance_criteria` must be filled.
- `in_progress_design` — `pbi-pipeline` Design phase: `pbi-designer` + `codex-design-reviewer` Round loop active.
- `in_progress_impl` — `pbi-pipeline` Impl phase: `pbi-implementer` writing source code.
- `in_progress_pbi_review` — Per-PBI Round review: `codex-impl-reviewer` + `codex-ut-reviewer` evaluating; FAIL loops back to `in_progress_impl`.
- `in_progress_ut_run` — Real test execution + coverage gate; FAIL loops back to `in_progress_impl`.
- `in_progress_merge` — Developer has signalled ready-for-merge (`mark-pbi-ready-to-merge.sh`); SM is about to run `merge-pbi.sh`.
- `awaiting_cross_review` — Per-PBI merge succeeded; PBI queued for the Sprint-end `cross-review` skill.
- `cross_review` — Sprint-end `cross-review` skill running for this PBI.
- `done` — Cross-review PASS. Definition of Done (FR-017) met.
- `escalated` — Developer-side gate trip OR SM-side merge failure (3 consecutive). Detail preserved in `pbi-state.json.escalation_reason` and `merge_failure.kind`. SM `pbi-escalation-handler` decides retry / hold / human-escalate.
- `blocked` — SM-decided hold (e.g., external blocker, requires human input). Reaches `in_progress_design` again once the blocker clears.

### Validation Rules
- `implementer_id` is set only when `status` is `refined` or later. There is no `reviewer_id` field — Sprint-end review is performed by the Scrum Master via independent reviewer sub-agents (see `cross-review` skill, FR-009 Layer 2).
- `design_doc_paths` is populated when design documents are produced (before `in_progress`).
- `acceptance_criteria` MUST be non-empty when transitioning from `draft` to `refined`.
- `depends_on_pbi_ids` is used by the Scrum Master to avoid placing dependent PBIs in the same Sprint (FR-008).
- `ux_change` is set during refinement and determines whether Sprint Review includes a live demo (FR-010).
- `parent_pbi_id` is set only for refined PBIs that were broken down from a draft PBI.
- The total number of PBIs with `status: refined` SHOULD stay within 6-12 (1-2 Sprints of capacity) to avoid over-refinement (FR-003). No global PBI count limit.

---

## Entity: Sprint

**File**: `.scrum/sprint.json`
**Owner**: Scrum Master (read/write)
**Readers**: Developer teammates (filtered), Textual dashboard app, statusline.sh

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (e.g., `"sprint-001"`) |
| `goal` | string \| null | Sprint Goal text |
| `base_sha` | string \| null | Captured `git rev-parse HEAD` at Sprint start (hex sha, 7-40 chars). PBI worktrees fork from this commit. Set once by `freeze-sprint-base.sh`; never re-written. |
| `base_sha_captured_at` | ISO 8601 string \| null | When `base_sha` was captured (set by `freeze-sprint-base.sh`). |
| `type` | enum | `"development"` or `"integration"` |
| `status` | enum | `"planning"`, `"active"`, `"cross_review"`, `"sprint_review"`, `"complete"`, `"failed"` |
| `developers` | Developer[] | Active Developer teammate definitions. Sprint PBI membership is derived from `backlog.items[]` where `sprint_id == sprint.id`; the developer count is `developers \| length`. (The legacy `pbi_ids` / `developer_count` fields were removed in the OD-4 single-source pass; pre-existing files retaining them keep validating because `sprint.schema.json.additionalProperties` is `true`, but no reader consults them.) |
| `started_at` | ISO 8601 string | Sprint start timestamp |
| `completed_at` | ISO 8601 string \| null | Sprint completion timestamp |

### Embedded: Developer

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Teammate identifier (e.g., `"dev-001-s3"`) |
| `assigned_work` | object | PBI assignments |
| `assigned_work.implement` | string[] | PBI IDs this Developer implements (per-PBI review is handled inside `pbi-pipeline`; Sprint-end cross-review is owned by SM) |
| `current_pbi` | string \| null | PBI ID currently being driven through `pbi-pipeline` (1 PBI at a time, sequential). Null between PBIs. |
| `status` | enum | `"active"` or `"failed"` (the dashboard renders `"unknown"` when no entry exists; not a writable value) |
| `sub_agents` | string[] | Names of specialist sub-agents actually invoked via the Task tool (runtime-populated, not candidates) |

> **Note**: The Developer's current PBI status is derived from
> `backlog.json.items[<current_pbi>].status` (12-value enum) — single
> source of truth, no mirror field to drift.

---

## Entity: SprintHistory

**File**: `.scrum/sprint-history.json`
**Owner**: Scrum Master (append-only, via `append-sprint-history.sh`)
**Readers**: Textual dashboard app, statusline.sh, `completion-gate.sh` (sprint_review exit criterion), `watchdog.sh` (max_sprints)

| Field | Type | Description |
|-------|------|-------------|
| `sprints` | SprintSummary[] | Completed Sprint summaries |

### Embedded: SprintSummary

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Sprint ID |
| `goal` | string | Sprint Goal |
| `type` | enum | Sprint type |
| `pbis_completed` | integer | Number of PBIs that reached `done` |
| `pbis_total` | integer | Number of PBIs in Sprint Backlog |
| `started_at` | ISO 8601 string | Start timestamp |
| `completed_at` | ISO 8601 string | Completion timestamp |

---

## Entity: ImprovementLog

**File**: `.scrum/improvements.json`
**Owner**: Scrum Master (read/write)
**Readers**: Developer teammates (at Sprint start)

| Field | Type | Description |
|-------|------|-------------|
| `entries` | Improvement[] | All improvement entries |
| `last_consolidation_sprint` | string \| null | Sprint ID of last 3-Sprint consolidation |

### Embedded: Improvement

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier |
| `sprint_id` | string | Sprint this was recorded in |
| `description` | string | What to improve |
| `status` | enum | `"active"`, `"archived"` |
| `created_at` | ISO 8601 string | When recorded |
| `archived_at` | ISO 8601 string \| null | When archived (during consolidation) |
| `dec_id` | string \| absent | Optional `dec-NNNN` link to a `po-decisions.json` record. Set by `append-improvement.sh --dec-id` in `po_mode=agent` when the entry derives from a PO decision; omitted otherwise. |

> **Note**: the legacy `category` field was removed from
> `improvements.schema.json` (commit e1958ec). Because the schema sets
> `additionalProperties: false`, any entry that still carries `category`
> now **fails** validation. See
> `docs/MIGRATION-scrum-state-tools.md`.

### Validation Rules
- Consolidation is designed to occur every 3 Sprints (FR-012) but is
  **not yet implemented**: `consolidate-improvements.sh` does not
  exist, so no writer currently sets `status: "archived"` /
  `archived_at` or bumps `last_consolidation_sprint`. Entries
  accumulate until the wrapper lands. See
  `docs/MIGRATION-scrum-state-tools.md` § Known gaps.
- Archived entries (once consolidation lands) are retained but not
  shown to Developers.

---

## Entity: RequirementsDocument

**File**: `docs/requirements.md`
**Format**: Markdown (not JSON — human-readable document)
**Owner**: Scrum Master (write once during Requirement Definition)
**Readers**: All Developer teammates, Integration Sprint
**Persistence**: Committed to repo (not runtime state)

This is the single source of truth for what the product must do. Produced
during the Requirement Definition (FR-002). Frozen during Development Sprints
(FR-020). Changes follow the Change Process (FR-016). Lives outside
`.scrum/` because the document outlives any single Sprint and must
survive across machine/clone boundaries.

---

## Entity: DesignCatalogConfig

**File**: `docs/design/catalog-config.json`
**Owner**: Scrum Master (read/write)
**Readers**: Developer teammates (read-only), status-gate.sh, scaffold-design-spec skill
**Reference**: `docs/design/catalog.md` (read-only document type catalog)

Controls which design spec types are active for the project. The full list
of recognized document types lives in `docs/design/catalog.md` (read-only,
managed in maul-team). This config file is the only editable part.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | string[] | Array of spec IDs from catalog.md that are active (e.g., `["D-001", "S-001", "S-010"]`) |

### Rules
- Only spec IDs that exist in `docs/design/catalog.md` may appear in `enabled`.
- The status-gate hook enforces that design spec files can only be created
  for IDs present in both `catalog.md` (exists) and `catalog-config.json`
  (enabled).
- When a spec ID is added to `enabled`, the `scaffold-design-spec` skill
  must be invoked to create template stubs.
- `catalog.md` is read-only in working directories; only this config file
  may be edited to control which entries are active.

---

## Entity: DesignDocument

**Directory**: `docs/design/specs/{category}/`
**Governance**: `docs/design/catalog.md` (type reference) + `docs/design/catalog-config.json` (enablement)
**Format**: Markdown with YAML frontmatter
**Owner**: Assigned Developer (write), Reviewer (read)
**Readers**: All Developers in subsequent Sprints (FR-004)

Design documents are governed by `docs/design/catalog.md` (read-only type
reference) and `docs/design/catalog-config.json` (editable enabled list). No
design document may be created unless its spec type is listed in the catalog
and enabled in the config. Files follow the naming convention
`docs/design/specs/{category}/{id}-{slug}.md`.

| Category | Example Entry | Example File |
|----------|--------------|-------------|
| system-wide | S-001 System Architecture | `system-wide/S-001-system-architecture.md` |
| data | S-010 Data Model | `data/S-010-data-model.md` |
| interface | S-020 API Specification | `interface/S-020-api-spec.md` |
| ui | S-030 Screen / Page Design | `ui/S-030-login-screen.md` |
| logic | S-040 Business Rule | `logic/S-040-auth-rules.md` |
| quality | S-050 Test Strategy | `quality/S-050-test-strategy.md` |
| decision-records | D-001 Architecture Decision Record | `decision-records/D-001-auth-api-choice.md` |
| operations | S-060 Migration / Upgrade | `operations/S-060-v2-migration.md` |
| technology | S-070 Library Specification | `technology/S-070-axios.md` |
| docs | D-011 README / Feature Documentation | `docs/D-011-readme.md` |

### YAML Frontmatter

```yaml
---
catalog_id: S-001
created_sprint: sprint-001
last_updated_sprint: sprint-003
related_pbis:
  - pbi-001
  - pbi-005
  - pbi-012
frozen: true
revision_history:
  - sprint: sprint-001
    author: dev-001-s1
    date: "2026-03-01T10:00:00Z"
    summary: "Initial architecture design"
    pbis: [pbi-001, pbi-005]
  - sprint: sprint-003
    author: dev-004-s3
    date: "2026-03-05T14:30:00Z"
    summary: "Added caching layer per PBI-012"
    pbis: [pbi-012]
    change_process: true
---
```

### Revision History (mandatory)

Every design document MUST include a `revision_history` array in its YAML
frontmatter to track edit history across Sprints. Each entry is a
`RevisionEntry` object:

| Field | Type | Description |
|-------|------|-------------|
| `sprint` | string | Sprint ID in which the edit was made |
| `author` | string | Developer ID who made the edit |
| `date` | ISO 8601 string | Timestamp of the edit |
| `summary` | string | One-line description of what changed |
| `pbis` | string[] | PBI IDs that triggered this edit (e.g., `["pbi-012"]`). Required for all entries |
| `change_process` | boolean \| absent | `true` if the document was frozen and FR-016 Change Process was followed. Omitted on initial creation |

### Rules
- **Catalog-first**: no design file may be created without an entry in
  `docs/design/catalog.md` AND an enabled entry in `docs/design/catalog-config.json`.
  The Scrum Master adds spec IDs to the config's `enabled` array during
  Sprint Planning.
- **Immediate stub creation**: when a spec ID is added to the `enabled`
  array in `catalog-config.json`, the Scrum Master invokes
  `scaffold-design-spec` to create a template stub with required
  frontmatter and placeholder sections. Developers populate the stub
  during the design phase.
- Multiple PBIs may reference the same design document.
- PBIs reference design documents via `design_doc_paths: string[]`
  (paths relative to project root, e.g., `docs/design/specs/ui/S-030-login.md`).
- Updates to existing documents follow FR-020 freeze/Change Process
  rules **and MUST append to `revision_history`**.
- Each `revision_history` entry MUST include `pbis`.
- Frozen after the Sprint in which they are created (FR-020).

---

## Entity: CommunicationsLog

**File**: `.scrum/communications.json`
**Owner**: Hook scripts (append-only)
**Readers**: Textual dashboard app (Work Log panel), statusline.sh

Stores agent-to-agent messages captured by Claude Code hooks —
SendMessage traffic (`message`), spawns (`agent_spawn`), and idle
progress reports (`progress_update`). Used by the Textual dashboard's
Work Log panel (FR-014c), which merges these messages chronologically
with the work events from `.scrum/dashboard.json`.

| Field | Type | Description |
|-------|------|-------------|
| `messages` | CommunicationMessage[] | Ordered list of agent messages |
| `max_messages` | integer | Maximum messages to retain (default: 200, oldest trimmed) |

### Embedded: CommunicationMessage

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | ISO 8601 string | When the message was sent |
| `sender_id` | string | Agent ID of the sender (e.g., `"scrum-master"`, `"dev-001-s3"`) |
| `sender_role` | enum | Sender role. SSOT: `communications.schema.json`. Allowed values: `"scrum-master"`, `"developer"`, `"teammate"`, `"sub-agent"`, `"coordinator"`, `"system"` (lowercase-hyphenated; free-form title-case strings fail validation) |
| `recipient_id` | string \| null | Agent ID of the recipient; null = broadcast to all |
| `type` | enum | Message type. SSOT: `docs/contracts/scrum-state/communications.schema.json`. Allowed values: `"file_changed"`, `"tool_use"`, `"status_transition"`, `"subagent_start"`, `"subagent_stop"`, `"task_completed"`, `"teammate_idle"`, `"agent_spawn"`, `"progress_update"`, `"message"`, `"report"`, `"review"`, `"escalation"`, `"info"`. Shares the past-tense-verb convention of `dashboard.events[].type` but is a distinct, larger enum (that one is a smaller 7-value set — the two are not identical). Hooks (`hooks/dashboard-event.sh`) emit `message` (SendMessage), `agent_spawn`, and `progress_update`; the remaining kinds are schema-allowed but not currently emitted by any writer. |
| `content` | string | Human-readable message summary |
| `pbi_id` | string \| absent | Optional `pbi-NNN` link to the PBI the message concerns. Set by the writer (`hooks/dashboard-event.sh`) when the message concerns a PBI; omitted otherwise. |

### Rules
- Messages are appended by hook scripts (`hooks/dashboard-event.sh`) when
  Agent Teams messaging events are detected.
- The file is capped at `max_messages` entries; oldest are trimmed on each append.
- If the file does not exist, the first hook creates it with an empty `messages` array.
- Dashboard readers tolerate a missing or empty file gracefully.

---

## Entity: DashboardEvents

**File**: `.scrum/dashboard.json`
**Owner**: Hook scripts (append-only)
**Readers**: Textual dashboard app (Work Log panel), statusline.sh,
completion-gate.sh (in-flight subagent counting), watchdog.sh

Stores timestamped agent work events written by Claude Code hooks
(R2 Layer 2). Used by the Textual dashboard's Work Log panel
(FR-014d, merged chronologically with `communications.json` messages)
and the status line for real-time agent activity.

| Field | Type | Description |
|-------|------|-------------|
| `events` | DashboardEvent[] | Ordered list of recent events |
| `max_events` | integer | Maximum events to retain (default: 100, oldest trimmed) |

### Embedded: DashboardEvent

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | ISO 8601 string | When the event occurred |
| `type` | enum | Event type (SSOT: `dashboard.schema.json`): `"file_changed"`, `"status_transition"`, `"subagent_start"`, `"subagent_stop"`, `"task_completed"`, `"teammate_idle"`, `"stop_failure"` |
| `agent_id` | string \| null | Developer or agent ID that triggered the event |
| `pbi_id` | string \| null | Related PBI ID, if applicable |
| `file_path` | string \| null | Absolute or relative file path (populated when `type` is `"file_changed"`) |
| `change_type` | enum \| null | `"created"`, `"modified"`, or `"deleted"` (populated when `type` is `"file_changed"`) |
| `status_from` | string \| null | Previous PBI status (populated when `type` is `"status_transition"`) |
| `status_to` | string \| null | New PBI status (populated when `type` is `"status_transition"`) |
| `detail` | string | Human-readable event description |

### Rules
- Events are appended by hook scripts (`hooks/dashboard-event.sh`).
- The file is capped at `max_events` entries; oldest are trimmed on each append.
- If the file does not exist, the first hook creates it with an empty `events` array.
- Dashboard readers tolerate a missing or empty file gracefully.

---

## Entity: HookLog

**File**: `.scrum/hooks.log`
**Owner**: All hooks (append-only via `log_hook` from `hooks/lib/validate.sh`)
**Readers**: Developers (debugging)

Plain-text log of hook activity for debugging. Each line is a timestamped
entry in the format: `<ISO8601> [LEVEL] <hook_name>: <message>`.

Levels: `INFO`, `WARN`, `ERROR`.

### Constraints

- The file is auto-trimmed to 500 lines (newest kept) on each append.
- Created automatically on first log entry.
- Not required for any hook functionality — purely diagnostic.

---

## Entity: TestResults

**File**: `.scrum/test-results.json`
**Owner**: Developer teammates (write during Integration Tests via
  `record-test-result.sh`)
**Readers**: Scrum Master (quality gate), completion-gate.sh, Textual dashboard app
**Schema**: `docs/contracts/scrum-state/test-results.schema.json`

Tracks automated test execution results during Integration Tests.
Written by Developer teammates running the `smoke-test` skill and then
the `integration-tests` skill (which appends `integration_api` /
`integration_ui` / `design_coverage` / `manual_probe` TestCategories
and recomputes `overall_status`). All writes go through
`record-test-result.sh`, which upserts by category `name` (a suite
re-run replaces its same-named category, so the release gate sees
fresh counts), creates the file on first call, and recomputes
`overall_status` on every call. The `completion-gate.sh` hook blocks
the `integration_sprint` phase until the combined `overall_status` is
`"passed"` or `"passed_with_skips"`; it re-checks the same field on
`uat_release` exit to catch a regression introduced by a defect-fix
Sprint, and separately requires the `uat-release` skill's per-Sprint
UAT stories file before allowing that phase to end.

| Field | Type | Description |
|-------|------|-------------|
| `categories` | TestCategory[] | Results per test category |
| `overall_status` | enum | `"running"`, `"passed"`, `"passed_with_skips"`, `"failed"` (`"running"` is the pre-first-record transient) |
| `started_at` | ISO 8601 string | When testing began |
| `updated_at` | ISO 8601 string | Last update timestamp |

### Embedded: TestCategory

| Field | Type | Description |
|-------|------|-------------|
| `name` | enum | `"unit"`, `"integration"`, `"e2e"`, `"smoke"`, `"regression"`, `"browser"`, `"integration_api"`, `"integration_ui"`, `"design_coverage"`, `"manual_probe"` |
| `status` | enum | `"passed"`, `"failed"`, `"skipped"` |
| `total` | integer | Total number of tests |
| `passed` | integer | Tests that passed |
| `failed` | integer | Tests that failed |
| `skipped` | integer | Tests that were skipped |
| `errors` | TestError[] | Details for failed tests |
| `runner_command` | string | Command used to run the tests |
| `executed_at` | ISO 8601 string | When this category was executed |

### Embedded: TestError

| Field | Type | Description |
|-------|------|-------------|
| `test_name` | string | Name or identifier of the failed test |
| `message` | string | Error message or failure reason |

### Rules
- Created by Developer teammates during Integration Tests via the
  `smoke-test` skill, then extended by the `integration-tests` skill,
  which appends `integration_api` / `integration_ui` / `design_coverage`
  / `manual_probe` TestCategories and recomputes `overall_status` in
  place.
- The `completion-gate.sh` hook blocks session stop during the
  `integration_sprint` phase unless `overall_status` is `"passed"` or
  `"passed_with_skips"`, and blocks `uat_release` if a later re-run has
  regressed `overall_status` back to `"failed"`.
- The Scrum Master reads this file and gates the transition to
  `uat_release` on the combined `overall_status` (smoke-test +
  integration-tests categories).
- Categories with `status: "skipped"` do not block the overall status.

---

## Entity: ReviewResult

**File**: `.scrum/reviews/<pbi-id>-review.md`
**Format**: Markdown
**Owner**: Assigned Reviewer (write)
**Readers**: Implementer, Scrum Master

Cross-review results for a PBI. Created during the Sprint-end Review phase
(FR-009). Per-PBI pipeline reviews live separately under
`.scrum/pbi/<pbi-id>/{impl,ut}/review-r{n}.md`.

---

## Entity: PbiPipelineState

**File**: `.scrum/pbi/<pbi-id>/state.json`
**Owner**: Developer (conductor of `pbi-pipeline` skill)
**Readers**: Textual dashboard app, completion-gate.sh, pbi-escalation-handler skill

Per-PBI internal state managed by the `pbi-pipeline` skill while the PBI
is in flight. Tracks Round counters, sub-agent verdicts, and escalation
context.

| Field | Type | Description |
|-------|------|-------------|
| `pbi_id` | string | PBI identifier (matches `backlog.json.items[].id`) |
| `design_round` | integer | Current/last design Round (1..5; 0 before first) |
| `impl_round` | integer | Current/last impl+UT Round (1..5; 0 before first) |
| `design_status` | enum | `"pending"`, `"in_review"`, `"fail"`, `"pass"`, `"skipped"` (`"skipped"` on a kind=docs PBI) |
| `impl_status` | enum | `"pending"`, `"in_review"`, `"fail"`, `"pass"` |
| `ut_status` | enum | `"pending"`, `"in_review"`, `"fail"`, `"pass"`, `"skipped"` (`"skipped"` is schema-allowed but never written — a kind=docs PBI keeps `"pending"`) |
| `coverage_status` | enum | `"pending"`, `"fail"`, `"pass"`, `"skipped"` (`"skipped"` on a kind=docs PBI) |
| `escalation_reason` | enum \| null | Set when `backlog.json.items[].status == escalated`. See enum below. |
| `branch` | string \| absent | Worktree branch name (`pbi/<id>`). Absent until set; schema rejects null |
| `worktree` | string \| absent | Worktree path (`.scrum/worktrees/<pbi-id>/`). Absent until set; schema rejects null |
| `base_sha` | string \| absent | Sprint base SHA inherited at worktree creation. Absent until set; schema rejects null |
| `head_sha` | string \| absent | Latest commit SHA on `pbi/<id>`. Absent until set; schema rejects null |
| `paths_touched` | string[] | Files modified by the PBI (used by `merge-pbi.sh` verification) |
| `ready_at` | ISO 8601 string \| absent | Timestamp the Developer signalled ready-for-merge. Absent until set; schema rejects null |
| `merged_sha` | string \| absent | Merge commit SHA on main. Absent until set; schema rejects null |
| `merged_at` | ISO 8601 string \| absent | Merge completion timestamp. Absent until set; schema rejects null |
| `merge_failure` | object \| absent | `{kind, paths, pre_head_at_failure}` when most recent merge failed. Absent when no failure (schema rejects null; the field is removed via `del()`, not nulled, on the next success) |
| `merge_failure_count` | integer | Consecutive merge failures (resets on success; ≥3 → status `escalated`) |
| `websearch_attempted` | boolean \| absent | Once-per-PBI latch. When a web-searchable technical error recurs across 2 consecutive impl Rounds, the Developer **conductor** runs `WebSearch` and pastes the findings into the next Round's feedback file, then sets this `true` so at most one remediation Round is spent per PBI. Never reset within a PBI lifecycle. See `skills/pbi-pipeline/references/termination-gates.md` § Technical-error recurrence |
| `started_at` | ISO 8601 string | PBI pipeline start timestamp |
| `updated_at` | ISO 8601 string | Last state mutation timestamp |

> **Note**: The legacy `phase` field was removed in v2. Lifecycle is
> driven by `backlog.json.items[].status` (12-value enum, see PBI
> entity above).

`escalation_reason` enum:

```text
stagnation | divergence | max_rounds | budget_exhausted |
requirements_unclear | coverage_tool_error | coverage_tool_unavailable |
catalog_lock_timeout |
reviewer_unavailable | stale_review_snapshot |
merge_conflict | merge_artifact_missing | merge_regression |
kind_mismatch
```

### Companion artifacts (under `.scrum/pbi/<pbi-id>/`)

| Path | Purpose |
|------|---------|
| `design/design.md` | Primary design artifact authored by `pbi-designer` (includes the `Library Selection` section) |
| `design/review-r{n}.md` | `codex-design-reviewer` output per Round |
| `impl/review-r{n}.md` | `codex-impl-reviewer` output per Round |
| `impl/summary.md` | Final-Round impl summary (file list, change summary) |
| `ut/review-r{n}.md` | `codex-ut-reviewer` output per Round |
| `ut/summary.md` | Final-Round UT summary |
| `metrics/coverage-r{n}.json` | Normalized coverage report (see `docs/contracts/coverage-rN.schema.json`) |
| `metrics/test-results-r{n}.json` | Normalized test results (see `docs/contracts/test-results-rN.schema.json`) |
| `metrics/pragma-audit-r{n}.json` | Pragma exclusion audit (see `docs/contracts/pragma-audit-rN.schema.json`) |
| `feedback/impl-r{n+1}.md` | Aggregated feedback for next-round `pbi-implementer` |
| `feedback/ut-r{n+1}.md` | Aggregated feedback for next-round `pbi-ut-author` |
| `pipeline.log` | Append-only event log: `<ISO8601>\t<phase>\t<round>\t<event>\t<detail>` |
| `escalation-resolution.md` | SM decision recorded by `pbi-escalation-handler` (only on escalation) |

### Companion lock directory

| Path | Purpose |
|------|---------|
| `.scrum/locks/catalog-<spec_id>.lock.d` | `mkdir` lock directory used by `pbi-designer` to serialize catalog spec writes across parallel PBIs (Layer 2 of `catalog-contention` defense). 60s timeout → `escalation_reason: catalog_lock_timeout`. |

### Rules

- The conductor MUST update `state.json` atomically (temp file + rename).
- Backlog `status: in_progress_merge`: for a kind=code PBI the conductor
  advances here only after all four `*_status` fields read `"pass"` — a
  pipeline **convention checked by the conductor, not machine-enforced**.
  `mark-pbi-ready-to-merge.sh` validates only that commits exist beyond
  base and records `paths_touched` / `head_sha` / `ready_at`; it does not
  inspect the `*_status` fields. A kind=docs PBI reaches this status with
  `design_status` and `coverage_status` = `"skipped"` and `ut_status` =
  `"pending"` instead.
- Backlog `status: escalated` requires `escalation_reason` to be non-null. When the cause is a merge failure, `merge_failure.kind` MUST also be set to one of `conflict`, `artifact_missing`, `regression` (corresponding `escalation_reason` values are `merge_conflict`, `merge_artifact_missing`, `merge_regression`).
- `coverage_status: pending` is permanent when `.scrum/config.json.coverage_tool` is `null` (project-wide coverage skip declared); evaluation logic skips this gate.

---

## Entity: Config

**File**: `.scrum/config.json` (optional; defaults apply if absent)
**Owner**: Project (authored by the user, or by `scrum-start.sh
  --autonomous` for the autonomy keys)
**Readers**: `pbi-pipeline` skill (test runner, coverage tool, path
  guard globs), `quality-gate.sh`, `pre-tool-use-path-guard.sh` (PO
  sandbox check), `hooks/lib/autonomy.sh`, `scripts/autonomous/watchdog.sh`

| Field | Type | Description |
|-------|------|-------------|
| `test_runner` | object \| absent | Per-language test command templates (`{pbi_id}`, `{round}` substituted). Documented in `.scrum-config.example.json`. |
| `coverage_tool` | object \| `null` \| absent | Per-language coverage tool. `null` disables the coverage gate project-wide. |
| `pragma_pattern` | string \| object \| absent | Pragma marker for the pragma-audit step — a plain string (single global marker, as in `.scrum-config.example.json`) or an object keyed per language. |
| `path_guard` | object \| absent | `impl_globs[]` and `test_globs[]` consumed by `pre-tool-use-path-guard.sh` for `pbi-implementer` / `pbi-ut-author`. |
| `merge_regression` | object \| absent | `command` run by `merge-pbi.sh` after each per-PBI merge; skipped with WARN when absent. |
| `po_mode` | enum (`"human"` \| `"agent"`) \| absent | Who plays the Product Owner role. Absent or `"human"` → the user; `"agent"` → the `product-owner` teammate (see `agents/product-owner.md`). Default-absent preserves existing behavior bit-for-bit. |
| `po` | object \| absent | Settings for the autonomous PO (only consulted when `po_mode == "agent"`). |
| `po.max_clarification_rounds` | integer ≥ 0 | Max `PO_CLARIFY` round-trips per `PO_DECISION_REQUEST` before the PO must commit a decision with `assumption=true` (default 2 when key absent). |
| `po.max_integration_cycles` | integer ≥ 0 | Advisory cap on Integration-Sprint defect-fix loops before the PO must answer `release_decision=no_go`. |
| `autonomous` | object \| absent | Watchdog (Ralph-Loop) settings; populated by `scrum-start.sh --autonomous`. |
| `autonomous.max_iterations` | integer ≥ 1 | Hard cap on outer-loop iterations (default 50). |
| `autonomous.max_wall_clock_hours` | number ≥ 0 | Hard cap on wall-clock from `started_at` (default 8). |
| `autonomous.max_sprints` | integer ≥ 1 | Sprints to run per launch, counted from the startup baseline (`autonomy.json.sprint_baseline`): the watchdog stops once `sprint-history.sprints.length` reaches `baseline + max_sprints` (default 8). |
| `autonomous.max_consecutive_failures` | integer ≥ 1 | Consecutive zero-progress iterations before the watchdog gives up (default 3). |
| `autonomous.stop_block_budget_per_phase` | integer ≥ 1 | Per workflow phase, how many times `completion-gate.sh` may block exit before tripping the circuit breaker (default 8). |
| `autonomous.permission_mode` | enum (`"dontAsk"` \| `"bypassPermissions"`) | Passed to `claude -p --permission-mode` (default `"dontAsk"`). |
| `autonomous.notify_command` | string \| `null` | Shell command run on watchdog exit with `WATCHDOG_EXIT` in env. Failures are swallowed. |
| `autonomous.fallback_model` | string \| `null` | Passed to `claude -p --fallback-model` when non-null. |
| `stall_watchdog` | object \| absent | Settings for the external teammate-stall monitor `scripts/stall-watchdog.sh` (non-autonomous mode only). |
| `stall_watchdog.enabled` | boolean | When `false`, the daemon exits without nudging. Default `true`. |
| `stall_watchdog.idle_threshold_minutes` | integer ≥ 1 | Idle window (no `.scrum/dashboard.json` mtime AND no `.scrum/pbi/*/` mtime change) after which a nudge is sent. Default 15. |
| `stall_watchdog.cooldown_minutes` | integer ≥ 1 | Minimum gap between consecutive nudges. Default 15. |
| `stall_watchdog.poll_interval_seconds` | integer ≥ 1 | Sleep between iterations of the daemon's main loop. Default 60. |

`po_mode`, `po`, and `autonomous` are constrained by
`docs/contracts/scrum-state/config.schema.json`. Other keys are
tolerated via the schema's top-level `additionalProperties: true`
(the legacy de-facto contract `.scrum-config.example.json` still
documents them and is copied verbatim by `setup-user.sh`).

### Rules

- Direct edits via Write/Edit are blocked by
  `pre-tool-use-scrum-state-guard.sh`; the file is written by the
  user manually (interactive mode) or by `scrum-start.sh
  --autonomous` (autonomous mode).
- `po_mode` absent and `po_mode == "human"` are
  behaviourally identical — every Skill's "ask the user" prompt
  resolves to the human.
- The PO **cannot** mutate this file (`pre-tool-use-path-guard.sh`
  fences PO writes to `docs/product/**` and `.scrum/po/**`); the
  engineering-quality keys (`coverage`, `merge_regression`,
  `path_guard`, cross-review routing) are SM/engineering territory.

---

## Entity: Autonomy

**File**: `.scrum/autonomy.json` (created by `scrum-start.sh
  --autonomous`; absent in human mode)
**Owner**: Hook scripts (`hooks/lib/autonomy.sh`) and
  `scripts/autonomous/watchdog.sh`
**Readers**: `hooks/completion-gate.sh`, `hooks/session-context.sh`,
  `hooks/stop-failure.sh`, `scripts/autonomous/lib/report.sh`,
  the Textual dashboard

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | string (UUID or `run-<ts>-<pid>`) | Unique identifier for one autonomous-PO run. |
| `started_at` | ISO 8601 string | When the watchdog booted this run. |
| `lead_session_id` | string \| `null` | Session id issued by the watchdog for the current `claude -p` iteration. `is_lead_session()` compares against this to gate the autonomous Stop-hook extension. |
| `watchdog_pid` | integer \| `null` | PID of the live Ralph-Loop watchdog, set at watchdog startup and cleared on clean exit. `autonomy_loop_active()` checks `kill -0 watchdog_pid` so the autonomous Stop-block policy applies only while a watchdog is actually driving the loop; otherwise the gate degrades to human-mode behaviour. |
| `sprint_baseline` | integer ≥ 0 \| absent | `sprint-history.sprints.length` captured at watchdog startup. `autonomous.max_sprints` is measured relative to this baseline (the watchdog stops once history reaches `sprint_baseline + max_sprints`), not cumulatively. Absent on a fresh `scrum-start.sh --autonomous` init; the watchdog captures and persists it on first startup and preserves it on resume. |
| `iteration` | integer ≥ 0 | Current outer-loop iteration counter (0 before the first iteration). |
| `total_cost_usd` | number ≥ 0 | Cumulative `total_cost_usd` summed from each `iter-<N>.json` output. |
| `stop_blocks` | object `{phase, count}` | Stop-block counter for the current workflow phase. Reset to `{phase, 1}` on phase change by `bump_stop_block_counter`. |
| `circuit_breaker_tripped` | object `{phase, at}` \| `null` | Set by `record_circuit_breaker` when `stop_blocks.count` exceeds `autonomous.stop_block_budget_per_phase`. Cleared by the watchdog at the start of the next iteration. |
| `last_failure` | object `{reason, at}` \| `null` | Most recent unrecoverable failure observed by the watchdog or persisted by `stop-failure.sh`. |
| `updated_at` | ISO 8601 string | Touched on every mutation. |

### Rules

- **No wrapper script.** Writes go through library helpers in
  `hooks/lib/autonomy.sh` (`bump_stop_block_counter`,
  `record_circuit_breaker`, `autonomy_atomic_write` in the
  watchdog) — there is no `.scrum/scripts/*.sh` for `autonomy.json`.
  This is not a lone exception: several `.scrum/` files are hook- or
  launcher-written rather than wrapper-written. The canonical
  per-file writer table is
  `docs/contracts/scrum-state/README.md`. The schema is enforced by
  the watchdog on rotation, not per call; the runtime hot-path is
  latency-sensitive.
- **Agent writes blocked.** Direct Write/Edit by any agent is
  rejected by `pre-tool-use-scrum-state-guard.sh`; the only
  permitted writers are the hook process and the watchdog
  process.
- **Fail-open.** Missing file, malformed JSON, or unreadable
  counter values must never crash a hook — the hooks fall back to
  "autonomy disabled" or "not lead" semantics.
- Schema: `docs/contracts/scrum-state/autonomy.schema.json`.

---

## Entity: PoDecisions

**File**: `.scrum/po/decisions.json` (created on first
  `append-po-decision.sh` invocation; absent until then)
**Owner**: `scripts/scrum/append-po-decision.sh` (deployed as
  `.scrum/scripts/append-po-decision.sh`) — the only permitted
  writer
**Readers**: `product-owner` agent (on respawn, last 20 entries),
  `po-acceptance` skill, retrospectives, morning report

Append-only audit log of every Product Owner decision (whether
human or autonomous). Schema:
`docs/contracts/scrum-state/po-decisions.schema.json`.

| Field | Type | Description |
|-------|------|-------------|
| `decisions[]` | PoDecision[] | Ordered list of decisions, oldest first. |

### Embedded: PoDecision

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Auto-assigned `dec-NNNN` (zero-padded). The wrapper echoes this on stdout; the PO must include it in the `PO_DECISION` reply so SM can back-link. |
| `timestamp` | ISO 8601 string | When the decision was recorded. |
| `kind` | enum (13 values) | `sprint_goal_approval` \| `pbi_split` \| `escalation_choice` \| `spec_clarification` \| `change_request` \| `demo_acceptance` \| `uat_item` \| `defect_triage` \| `release_decision` \| `git_dirty` \| `backlog_approval` \| `scope_change` \| `sprint_continuation` (Retrospective → next-Sprint handshake; `decision ∈ {choice:next_sprint, choice:integration_sprint, choice:complete}`). |
| `sprint_id` | string \| `null` | Set when scope is sprint-bound (`sprint-N` pattern). |
| `pbi_id` | string \| `null` | Set when scope is PBI-bound (`pbi-N` pattern). |
| `request` | string \| absent | Summary of what SM asked the PO to decide. |
| `decision` | string | Verdict text (`approve`/`reject`/`go`/`no_go`/`pass`/`fail`/`waive`/`choice:<label>`). |
| `rationale` | string | Why this decision was made. Required even for autonomous PO so post-hoc review is possible. |
| `evidence[]` | string[] \| absent | Paths/anchors that ground the decision. **Required** (non-empty) for `kind ∈ {demo_acceptance, uat_item, release_decision}` — enforced by the wrapper. |
| `assumption` | boolean | `true` iff the PO committed under best-effort with unverified assumptions (clarification budget exhausted etc.). Used to flag risky decisions for human review. |

### Companion artifacts (under `.scrum/po/`)

| Path | Purpose |
|------|---------|
| `.scrum/po/decisions.json` | This entity. |
| `.scrum/po/acceptance/<sprint-id>/<pbi-id>.md` | Per-PBI demo-mode `po-acceptance` transcript; referenced as `evidence` on the matching `demo_acceptance` decision. |
| `.scrum/po/acceptance/<sprint-id>/<pbi-id>-r<n>.md` | Re-entry transcript when `po-acceptance` is re-run for a defect-fix loop. |
| `.scrum/po/uat-<sprint-id>.md` | Single UAT-mode transcript per Sprint; section anchors are referenced as `evidence` on `uat_item` decisions. |
| `.scrum/po/uat-stories-<sprint-id>.md` | UAT user-story inventory derived from `docs/requirements.md` with FR⇄US traceability appendix; each story (`US-NNN`) carries a verdict (`pass \| fail \| waive` + feedback) recorded during the walkthrough. One file per Sprint. |
| `.scrum/po/attention.md` | Human-only queue: numbered entries the PO appended for issues only a human can resolve (credentials, billing, legal, prod deploy). Entries tagged `release-blocking: yes` block `release_decision=go`. |

### Rules

- **Append-only.** IDs are auto-assigned (monotonically
  increasing `dec-NNNN`); the wrapper never rewrites existing
  records. Direct Write/Edit is blocked by
  `pre-tool-use-scrum-state-guard.sh`.
- **Evidence gate.** For `kind ∈ {demo_acceptance, uat_item,
  release_decision}` the wrapper rejects calls with no
  `--evidence` flag — no evidence, no approval.
- **Release gate.** `kind=release_decision` with
  `decision=go` also requires `.scrum/test-results.json` to exist
  with `overall_status ∈ {passed, passed_with_skips}`; `no_go`
  may be recorded freely.
- **Wrapper-only writes.** Agents call
  `.scrum/scripts/append-po-decision.sh`; library code never opens
  the file directly.
- **PO writes only.** The path-guard hook restricts the
  `product-owner` agent to `docs/product/**` and `.scrum/po/**`,
  so this file (under `.scrum/po/`) is the only `.scrum/` JSON the
  PO may indirectly mutate — and even then, only via the wrapper.

---

## Entity: StopGateLedger

**File**: `.scrum/stop-gate.json` (created on first human-mode block;
  absent until then; absent entirely in autonomous mode)
**Owner**: `hooks/lib/stop-gate-state.sh` (sourced by
  `hooks/completion-gate.sh`) — atomic tmp + mv writes
**Readers**: `hooks/completion-gate.sh` only

Human-mode dedup ledger for the Stop hook. Records the most recent
`<phase, fingerprint>` pair plus a counter so repeated identical
Stop blocks collapse to a single notification per situation: the
first block emits the verbose reason and exits 2; subsequent
blocks for the same `<phase, fingerprint>` are logged-only and
allow exit. Phase change or fingerprint change resets
`block_count` to 1.

| Field | Type | Description |
|-------|------|-------------|
| `phase` | string | The `state.json.phase` at the recorded block. |
| `fingerprint` | string | Stable identifier of the block-triggering situation within the phase (e.g. `review_incomplete\|pbi-001,pbi-003`, `sprint_history_missing\|sprint-002`). Caller-defined; any change resets `block_count`. |
| `block_count` | integer ≥ 1 | Number of consecutive Stop blocks observed for the current `<phase, fingerprint>`. |
| `first_block_at` | ISO 8601 string | When the first block of this situation was recorded. |
| `last_block_at` | ISO 8601 string | When the most recent block was recorded; refreshed on every REPEAT. |

### Rules

- **Human mode only.** In autonomous mode the Stop hook bypasses
  the ledger entirely (no dedup is wanted there), so the file is
  never created in that mode.
- **No wrapper script.** Like `autonomy.json`, writes go through
  a hook-side library (`stop_gate_check_and_bump` in
  `hooks/lib/stop-gate-state.sh`) — there is no
  `.scrum/scripts/*.sh` for `stop-gate.json`. The hook runs
  outside the agent's Bash/Write/Edit tool surface, so
  `pre-tool-use-scrum-state-guard.sh` (which only intercepts
  those tools) does not apply; agent direct edits via Write/Edit
  are still rejected by that guard.
- **Fail-open toward block.** Any I/O / JSON failure path emits
  `FIRST` (verbose block) rather than `REPEAT` so the gate is
  never silently muted by a corrupted ledger.
- Schema: `docs/contracts/scrum-state/stop-gate.schema.json`.
- The Stop-hook block policy this ledger implements (human-mode
  fingerprint-dedup vs the autonomous circuit breaker, and the
  `pbi_pipeline_active` escalated-only rule) is specified in
  [agent-interfaces.md](contracts/agent-interfaces.md) § Stop Hook.

---

## Entity: Runtime

**File**: `.scrum/runtime.json` (created by `scrum-start.sh` when
  tmux is available; absent in the no-tmux fallback)
**Owner**: `scrum-start.sh` — writes the initial record at session
  launch and then patches `stall_watchdog_pid` after the daemon
  forks. Atomic tmp + mv via `jq`. No wrapper script.
**Readers**: `scripts/stall-watchdog.sh` (resolves `tmux_session`
  and `sm_pane_id` on each iteration; exits when the session no
  longer exists)

| Field | Type | Description |
|-------|------|-------------|
| `tmux_session` | string | tmux session name (`scrum-team-<sanitized-basename>-<pwd-hash>`). |
| `sm_pane_id` | string | tmux pane id (`%N`) of the Scrum Master pane, captured before any split-window. Used as the target for `tmux send-keys` nudges. |
| `started_at` | ISO 8601 string | When the tmux session was created. |
| `stall_watchdog_pid` | integer \| `null` | PID of the detached `scripts/stall-watchdog.sh` daemon. `null` in autonomous mode (the Ralph-Loop watchdog owns liveness, no stall daemon is launched). |

### Rules

- **No wrapper.** Outside the `.scrum/scripts/*.sh` SSOT writer
  set — see CLAUDE.md § State management. Agent direct
  Write/Edit/raw-Bash edits to `.scrum/runtime.json` are still
  rejected by `pre-tool-use-scrum-state-guard.sh` (it matches all
  `.scrum/*.json` paths); only `scrum-start.sh` writes the file.
- **Absent → degraded mode.** When `runtime.json` is missing or
  unreadable, the stall watchdog logs a warning and skips its
  iteration without crashing.
- **No schema today.** Format is ad-hoc; readers tolerate missing
  or invalid fields by falling through.

---

## File Relationships

```
state.json
  └── current_sprint_id -> sprint.json.id

backlog.json
  └── items[] | select(.status | startswith("in_progress_"))
        -> .scrum/pbi/<pbi-id>/state.json (PbiPipelineState)
       (active pipelines are derived from backlog status, not a separate field)

backlog.json
  └── items[].sprint_id -> sprint.json.id
  └── items[].implementer_id -> sprint.json.developers[].id
  └── items[].design_doc_paths[] -> docs/design/specs/{category}/{id}-{slug}.md
                                  | .scrum/pbi/<pbi-id>/design/design.md
  └── items[].review_doc_path -> .scrum/reviews/<pbi-id>-review.md
  └── items[].catalog_targets[] -> docs/design/specs/{category}/{id}-{slug}.md
  └── items[].parent_pbi_id -> items[].id (self-reference)
  └── items[].depends_on_pbi_ids[] -> items[].id (cross-reference)

sprint.json
  └── developers[].current_pbi -> backlog.json.items[].id
  └── developers[].assigned_work.implement[] -> backlog.json.items[].id
  └── (Sprint PBI set is derived: backlog.json.items[] where sprint_id == sprint.id)

.scrum/pbi/<pbi-id>/state.json (PbiPipelineState)
  └── pbi_id -> backlog.json.items[].id

improvements.json
  └── entries[].sprint_id -> sprint-history.json.sprints[].id

communications.json
  └── messages[].sender_id -> sprint.json.developers[].id | "scrum-master"
  └── messages[].recipient_id -> sprint.json.developers[].id | "scrum-master" | null

dashboard.json
  └── events[].agent_id -> sprint.json.developers[].id
  └── events[].pbi_id -> backlog.json.items[].id

test-results.json
  (standalone — no foreign key references; read by completion-gate.sh and dashboard)

config.json
  └── po_mode -> rules/scrum-context.md § PO seat resolution (selects PO seat)
  └── po.* -> agents/product-owner.md § Anti-loop rules (read by PO teammate)
  └── autonomous.* -> .scrum/autonomy.json + scripts/autonomous/watchdog.sh

autonomy.json
  └── lead_session_id -> claude session id of the current `claude -p` iteration
                         (matched by hooks/lib/autonomy.sh::is_lead_session)
  └── stop_blocks.phase -> state.json.phase (resets when phase changes)
  └── circuit_breaker_tripped.phase -> state.json.phase

po/decisions.json
  └── decisions[].sprint_id -> sprint.json.id | sprint-history.json.sprints[].id
  └── decisions[].pbi_id    -> backlog.json.items[].id
  └── decisions[].evidence[] -> .scrum/po/acceptance/<sprint-id>/<pbi-id>.md (demo)
                              | .scrum/po/uat-<sprint-id>.md#us-nnn        (uat)
                              | .scrum/test-results.json                   (release_decision=go)

stop-gate.json
  └── phase -> state.json.phase (reset on phase change)
  (human-mode only; absent in autonomous mode)

runtime.json
  └── tmux_session, sm_pane_id, stall_watchdog_pid
        -> consumed by scripts/stall-watchdog.sh (non-autonomous mode)
```
