---
name: cross-review
description: >
  Sprint-end product-wide integrity gate. The five per-aspect reviews
  (requirement conformance, functional quality, security,
  maintainability, docs consistency) now run PER-PBI inside the pipeline
  before a PBI reaches awaiting_cross_review. Sprint-end cross-review is
  the whole-repo codebase-audit ONLY: static analysis + 4 audit axes
  (spec-conformance, logic-defect, redundancy, product-security) over the
  accumulated codebase at HEAD. The audit is non-blocking — Critical/High
  findings become draft PBIs for the next Sprint; it never reverts a PBI.
disable-model-invocation: false
---

## Role

Sprint-end cross-cutting quality gate — now scoped to **product-wide
integrity**. Two things changed the shape of this ceremony:

1. **The five aspect reviews moved into the per-PBI pipeline.**
   Requirement conformance, cross-PBI functional quality, security,
   maintainability, and docs consistency are reviewed **per PBI**,
   inside the pipeline, before the PBI reaches `awaiting_cross_review`.
   Their per-PBI review docs and `review_doc_path` are authored there,
   not here. This skill no longer spawns aspect reviewers, writes
   `aspect-*.md`, builds per-PBI digests, or runs any aspect FAIL
   routing / re-loop.

2. **Sprint-end cross-review is the whole-repo `codebase-audit`.** It
   scans the **accumulated codebase at HEAD** — the scope no per-PBI
   diff review can reach — along four axes:

   | Axis | Catches (only visible whole-repo) |
   |---|---|
   | `spec-conformance` | Divergences, coded-but-unspecified behavior, spec-vs-spec conflicts |
   | `logic-defect` | Feature-disabling defaults, silent failures, wiring-layer edge cases |
   | `redundancy` | Dead exports (static-analysis-grounded), cross-PBI duplication, stale docs |
   | `product-security` | Cross-component authz, trust-boundary data flow, whole-repo secret handling, integration-point injection surfaces |

The audit is **non-blocking**: PBIs already passed their per-PBI aspect
reviews before reaching this ceremony, so the audit never reverts them.
Its Critical/High findings become draft PBIs for the **next** Sprint
(separate `codebase-audit-s{N}.md` report, identity-deduped across
Sprints). At ceremony end every reviewed PBI transitions
`cross_review → done`. Full audit protocol:
`skills/codebase-audit/SKILL.md` (context (a)) +
`skills/codebase-audit/references/axes.md`.

## Inputs

- `state.json` (overall project phase: `pbi_pipeline_active` or `review`)
- `backlog.json` → all Sprint PBIs at
  `status ∈ {awaiting_cross_review, escalated}` (id, title). Only
  `awaiting_cross_review` PBIs are carried to `done`; `escalated` PBIs
  are not touched here.
- `requirements.md` + `docs/design/catalog-config.json` +
  `docs/design/specs/**` — audit inputs (spec-conformance axis).
- `.scrum/po/decisions.json` — PO decision log (spec-conformance axis
  checks it before flagging a spec-vs-spec conflict).
- Sprint base SHA: `sprint.base_sha` (static-analysis Pass A diff scope).
- Project source code + test suites (whole repo at HEAD — the audit
  scope).
- `skills/codebase-audit/SKILL.md` (context (a)) +
  `skills/codebase-audit/references/axes.md` — the 4-axis protocol.

## Outputs

- `.scrum/reviews/static-analysis-r{n}.json` — two-pass static-analysis
  output (feeds the `redundancy` audit axis; round `n` increments if the
  ceremony is re-run).
- `.scrum/reviews/codebase-audit-s{N}.md` — the whole-repo audit report
  (`N` = numeric sprint number).
- Draft `[codebase-audit:<sprint-id>:F<n>:<Severity>]` PBIs for the
  **next** Sprint (non-blocking; Critical/High mandatory, identity-deduped
  across Sprints; `[REGRESSION]`-tagged when a closed finding recurs).
- `backlog.json` `items[].status` transitions:
  - At start: `awaiting_cross_review → cross_review`.
  - At end: `cross_review → done` (every reviewed PBI; the audit never
    reverts).
- `state.json` overall phase: `review`.
- `sprint.json.status: "cross_review"`.

## Preconditions

- Every Sprint PBI is at backlog
  `status ∈ {awaiting_cross_review, escalated}`. Anything else must be
  driven to one of those terminal values (via `pbi-merge` or
  `pbi-escalation-handler`) before this skill runs.
- **Each `awaiting_cross_review` PBI has already passed its per-PBI
  aspect review in the pipeline** (per-PBI review doc + `review_doc_path`
  authored there). This ceremony assumes per-PBI quality is settled and
  does not re-evaluate it.
- Review target: merged main HEAD.
- `sprint.json.base_sha` is set (captured at Sprint start).
- App builds + starts (verified during implementation; if uncertain →
  re-verify).

## Steps

1. **Set ceremony state.** Phase + Sprint status + per-PBI status:
   ```bash
   .scrum/scripts/update-state-phase.sh review
   .scrum/scripts/update-sprint-status.sh cross_review
   for PBI_ID in $(jq -r '.items[] | select(.sprint_id == "<sprint-id>" and .status == "awaiting_cross_review") | .id' .scrum/backlog.json); do
     .scrum/scripts/update-backlog-status.sh "$PBI_ID" cross_review
   done
   ```
2. **Sanity check.** Every Sprint PBI now at
   `status ∈ {cross_review, escalated}`. No `awaiting_cross_review` /
   `in_progress_*` left.
3. **Pre-review build verification.** Start app → all tests pass.
   Fail → `TaskGet` Developer status → terminated? re-spawn (Teammate
   Liveness Protocol) → relay fix request. Do NOT audit non-building
   code.
4. **Collect the static-analysis source scope.** Build the Sprint-wide
   source path union (files this Sprint touched) for Pass A:
   ```bash
   git diff --name-only "$(jq -r '.base_sha' .scrum/sprint.json)"..HEAD \
     | grep -vE '^docs/|\.md$' \
     > .scrum/reviews/sprint-impl-diff.txt
   ```
   (The audit axes themselves are whole-repo and do not need this diff;
   it only scopes Pass A of the static analysis below.)
5. **Run static analysis (feeds the `redundancy` audit axis).**
   Determine the round counter `n` (next integer; first round = `1`):
   ```bash
   ROUND=$(ls .scrum/reviews/static-analysis-r*.json 2>/dev/null \
     | sed -E 's|.*static-analysis-r([0-9]+)\.json|\1|' \
     | sort -n | tail -1)
   ROUND=$(( ${ROUND:-0} + 1 ))
   ```
   The analysis runs in **two passes** whose findings both land in the
   single `.scrum/reviews/static-analysis-r${ROUND}.json` file (one
   `tools[]` entry per tool invocation, from either pass). Both passes
   now feed the audit's `redundancy` axis — there is no separate
   Sprint-level maintainability aspect consumer any more.

   **Pass A — intra-file lint (Sprint-diff scope).** Run on the
   Sprint-wide source path union (files this Sprint touched):
   - Python sources → `ruff check --select F401,F841,ARG,B --output-format json`
   - Shell sources → `shellcheck -f json`
   - (Other languages: skip; the redundancy axis degrades gracefully.)

   These catch within-file unused imports / locals / arguments — a
   symbol that is dead **inside** a file the Sprint edited.

   **Pass B — dead-export / reachability scan (whole-repo scope).**
   Run on the **entire project source tree, not the Sprint diff.**
   Rationale: a symbol goes dead when its *last caller* changes in
   this Sprint, but the now-unreachable definition (the corpse) lives
   in a file the Sprint never touched — so a diff-scoped pass structurally
   cannot see it. Only a whole-repo reachability scan surfaces
   cross-PBI-boundary dead exports.

   Tool selection for Pass B:
   - If `.scrum/config.json.static_analysis.commands[]` is present and
     non-empty, run **each** declared command via `bash -c` from the
     repo root, capturing stdout + exit code. This is the path for
     languages the built-in default does not cover — e.g. `knip` /
     `ts-prune` (TypeScript), `staticcheck` (Go), `cargo-udeps`
     (Rust). The project owns path scoping inside its command string.
   - Otherwise (no declared commands), fall back to the built-in
     Python default: if `command -v vulture` succeeds **and** the tree
     has Python sources, run `vulture` over the project source
     dir(s) (e.g. `vulture src/`). If `vulture` is not installed,
     record a `tools[]` entry named `vulture` with a non-zero
     `exit_code` and an empty `findings[]` (tool unavailable) and
     degrade gracefully — do NOT abort.

   **Aggregation / normalization.** Aggregate both passes into
   `.scrum/reviews/static-analysis-r${ROUND}.json` as
   `{"tools": [{"name", "exit_code", "findings": [...]}...],
   "skipped_reason"?}` — one `tools[]` entry per invocation, each
   `findings[]` entry `{file, line, message, kind, code}`. `ruff` and
   `shellcheck` already emit JSON. `vulture` (and most Pass-B tools)
   emit **plain text lines** like
   `path/to/file.py:42: unused function 'foo' (60% confidence)` — the
   SM parses each line into a `findings[]` entry (`file`, `line`,
   `message`, `kind`; set `code` to the tool name when the tool has no
   rule code) and maps the phrase to `kind`: `unused function` /
   `unused class` / `unused method` at module scope →
   `unused_export`; `unused import` → `unused_import`; `unused
   variable` → `unused_variable`; else `other`. On any tool failure,
   set that `tools[].exit_code` to the non-zero code AND keep going —
   do NOT abort the skill.

   If **every** tool across both passes fails OR no source files match
   any supported/declared tool, set `skipped_reason` to a short string
   (e.g. `"no python/shell sources; no static_analysis.commands
   configured"`); the `redundancy` axis will degrade accordingly.
6. **Announce expected duration to the user (mandatory).** Before
   spawning, output a single short notice so the user does not
   interpret silence or `completion-gate.sh` Stop-blocks as failure
   and try to `/clear` the session mid-audit. Target-project
   retrospectives showed this UX failure 5 Sprints in a row before the
   announcement convention was made explicit. Use this exact wording
   so the user learns to recognise it:

   > "Cross-review: コードベース監査 4 軸を並列起動します。完了まで 60-120
   > 秒（最大 5 分）。その間 `completion-gate.sh` がセッション終了をブロック
   > します。もし 5 分以上応答がなければここに声をかけてください。"

   Then, and only then, spawn the audit axes in the next step.
7. **Spawn the 4 codebase-audit axes in parallel** via the `Agent`
   tool — one `Agent` call per axis (`spec-conformance`,
   `logic-defect`, `redundancy`, `product-security`),
   `run_in_background: true`, single message. Each carries the common
   protocol + its axis prompt from
   `skills/codebase-audit/references/axes.md` and the Step-1 read set
   from `skills/codebase-audit/SKILL.md` (enabled specs,
   `requirements.md`, PBI summary, and the Step 5 static-analysis file
   as the `redundancy` axis's ground truth). The axes are **whole-repo**
   — no kind partition, no per-PBI fan-out; all 4 always run, even on a
   docs-only Sprint.

   **File ownership.** Audit axes are read-only and return their
   findings **as their final assistant message**. The SM synthesizes
   them into the audit report in Step 8. Do NOT ask an axis to write any
   file — tell each explicitly: "Return your findings as your final
   message; the orchestrator persists the report."

   **Wait barrier.** After spawning, wait for **all 4** Tasks to reach
   `Status = completed`. Do NOT attempt to stop the session in between.
   Completion typically takes 60-120s — do NOT interpret a Stop hook
   block (`completion-gate.sh` "PBIs not done") as a failure. Synthesis
   is Step 8's job, after `Status = completed` — do NOT wait for the
   report file to appear. See `agents/scrum-master.md` § Background
   Subagent + Stop Hook Reading.

   **Axes are single-shot.** `Status = completed` is the success signal
   — do NOT apply the Teammate Liveness Protocol re-spawn rule meant for
   Developer teammates. If an axis's final message is missing or empty,
   re-spawn that single axis. After each completes, `git status` must be
   clean (read-only is prompt-enforced) — discard any edits and re-run
   if dirty.
8. **Synthesize the audit report + file next-Sprint PBIs** per
   `skills/codebase-audit/SKILL.md` context (a), Steps 3–5:
   - Read the 4 axis final messages; dedup within the audit (a
     cross-boundary defect landing on two axes counts once, keep the
     higher severity, note both axes); write the report to
     `.scrum/reviews/codebase-audit-s{N}.md` (`N` = numeric sprint
     number). The `redundancy` axis is grounded in the Step-5
     static-analysis file (it is the sole Sprint-level owner of
     whole-repo dead-code findings).
   - Route Critical/High findings to the **next** Sprint as draft PBIs
     (`[codebase-audit:<sprint-id>:F<n>:<Severity>]`) with the
     cross-Sprint **content dedup** (skip if an open PBI already tracks
     the finding's `identity`; `[REGRESSION]` if a closed one recurred);
     Medium/Low at PO discretion. This does **not** revert any PBI or
     transition the phase — the audit is strictly non-blocking. Full
     rules + the dedup `jq` live in `skills/codebase-audit/SKILL.md`.
   - PO routing is mode-agnostic — in `po_mode=agent` it resolves to one
     `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage
     options=[next_sprint,defer,reject]` carrying the finding list; the
     SM never blocks on human input.
9. **Mark every reviewed PBI done.** The PBIs already passed their
   per-PBI aspect reviews and the audit never reverts them:
   ```bash
   for PBI_ID in $(jq -r '.items[] | select(.sprint_id == "<sprint-id>" and .status == "cross_review") | .id' .scrum/backlog.json); do
     .scrum/scripts/update-backlog-status.sh "$PBI_ID" done
   done
   ```
   (`review_doc_path` was set by the per-PBI pipeline review, not here.)

Ref: FR-009

## Exit Criteria

- App builds + tests pass (verified before the audit).
- Static-analysis run recorded at
  `.scrum/reviews/static-analysis-r{n}.json` (or `skipped_reason`
  populated).
- `.scrum/reviews/codebase-audit-s{N}.md` synthesized with all 4 axes
  represented, findings deduped and severity-classified, fact separated
  from interpretation.
- Every Critical/High audit finding filed as a
  `[codebase-audit:*]` draft PBI for the next Sprint, or deduped against
  an existing open one (id noted); no duplicates. Audit findings did NOT
  revert any PBI or affect the phase.
- Every reviewed Sprint PBI (those at `awaiting_cross_review` at entry)
  ended at `status: done`.
- `state.json` overall phase: `review`; `sprint.json.status:
  cross_review`.
