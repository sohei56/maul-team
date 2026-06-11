---
name: cross-review
description: >
  Sprint-end cross-cutting quality gate. Scrum Master runs static analysis,
  then spawns 5 aspect-specialized reviewers in parallel (each reviews the
  whole Sprint, not per-PBI fan-out). FAIL routing is aspect-specific:
  aspects 1-3 revert PBIs to in_progress_impl, aspects 4-5 generate
  follow-up PBIs in the next Sprint.
disable-model-invocation: false
---

## Role

Sprint-end cross-cutting quality gate. The PBI Pipeline already runs
per-PBI impl + UT reviews via `codex-impl-reviewer` /
`codex-ut-reviewer`. This skill complements that with **aspect-separated
Sprint-wide review**, evaluated independently along five axes:

| # | Aspect | Reviewer agent | FAIL routing |
|---|---|---|---|
| 1 | Requirement conformance | `requirement-conformance-reviewer` | revert PBI → `in_progress_impl` |
| 2 | Cross-PBI functional quality | `functional-quality-reviewer`     | revert PBI → `in_progress_impl` |
| 3 | Security | `security-reviewer`                                    | revert PBI → `in_progress_impl` |
| 4 | Maintainability (static-analysis-grounded) | `maintainability-reviewer` | follow-up PBI in next Sprint |
| 5 | Docs consistency | `docs-consistency-reviewer`                    | follow-up PBI in next Sprint |

Each reviewer ingests the **entire Sprint Increment**, not per-PBI
slices. PBI mapping is recorded inside Findings via reverse-lookup
against `paths_touched`.

Do NOT duplicate per-PBI quality work; assume per-PBI Pass criteria
already satisfied (see `.scrum/pbi/<pbi-id>/impl/review-r{last}.md` and
`ut/review-r{last}.md` for prior context).

## Inputs

- `state.json` (overall project phase: `pbi_pipeline_active` or `review`)
- `backlog.json` → all Sprint PBIs at
  `status ∈ {awaiting_cross_review, escalated}`. Each PBI's
  `acceptance_criteria`, `title`.
- `.scrum/pbi/<pbi-id>/state.json` → `paths_touched` (set by
  `mark-pbi-ready-to-merge.sh` at handoff; not mirrored to `backlog.json`).
- `requirements.md` + relevant `docs/design/specs/**`
- Sprint base SHA: `sprint.base_sha` (for diff range)
- Per-PBI pipeline final reviews (read for context, NOT re-evaluated):
  - `.scrum/pbi/<pbi-id>/impl/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/ut/review-r{last}.md`
  - `.scrum/pbi/<pbi-id>/metrics/coverage-r{last}.json`
  - `.scrum/pbi/<pbi-id>/ut/ac-coverage-r{last}.json` (AC → test
    map; consumed by `requirement-conformance-reviewer`)
- Reviewer agent definitions:
  - `agents/requirement-conformance-reviewer.md`
  - `agents/functional-quality-reviewer.md`
  - `agents/security-reviewer.md`
  - `agents/maintainability-reviewer.md`
  - `agents/docs-consistency-reviewer.md`

## Outputs

- `.scrum/reviews/static-analysis-r{n}.json` — pre-review tool output
  (one file per cross-review round; round counter `n` increments per
  full FAIL re-loop)
- `.scrum/reviews/sprint-impl-diff.txt` — non-doc file diff list for
  `docs-consistency-reviewer`
- `.scrum/reviews/aspect-<aspect>-review.md` — raw output per aspect
  (5 files: `aspect-requirement-conformance-review.md`,
  `aspect-functional-quality-review.md`,
  `aspect-security-review.md`,
  `aspect-maintainability-review.md`,
  `aspect-docs-consistency-review.md`)
- `.scrum/reviews/<pbi-id>-review.md` — per-PBI digest combining all
  aspect Findings filtered to that PBI (existing schema preserved)
- `backlog.json` `items[].status` transitions:
  - At step 1: `awaiting_cross_review → cross_review`
  - On all aspects PASS: `cross_review → done`
  - On aspect 1/2/3 FAIL: `cross_review → in_progress_impl`
  - On aspect 4/5 FAIL: PBI itself stays / proceeds to `done`;
    a new follow-up PBI is appended to `backlog.json` with status
    `draft` for next Sprint
- `backlog.json` → `items[].review_doc_path` set to per-PBI digest
- `state.json` overall phase: `review`
- `sprint.json.status: "cross_review"`

## Preconditions

- Every Sprint PBI is at backlog
  `status ∈ {awaiting_cross_review, escalated}`. Anything else must
  be driven to one of those terminal values (via `pbi-merge` or
  `pbi-escalation-handler`) before this skill runs.
- Review target: merged main HEAD (only the PBIs at
  `awaiting_cross_review`; `escalated` PBIs are not reviewed here).
- `sprint.json.base_sha` is set (captured at Sprint start).
- App builds + starts (verified during implementation; if uncertain
  → re-verify).

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
   `status ∈ {cross_review, escalated}`. No
   `awaiting_cross_review` / `in_progress_*` left.
3. **Pre-review build verification.** Start app → all tests pass.
   Fail → `TaskGet` Developer status → terminated? re-spawn (Teammate
   Liveness Protocol) → relay fix request. Do NOT review non-building
   code.
4. **Collect review inputs.** For each Sprint PBI gather: design doc
   paths, `paths_touched`, `acceptance_criteria`. Build the
   Sprint-wide source path union for reviewers 1-4 and the
   `docs/**` + diff list for reviewer 5:
   ```bash
   git diff --name-only "$(jq -r '.base_sha' .scrum/sprint.json)"..HEAD \
     | grep -vE '^docs/|\.md$' \
     > .scrum/reviews/sprint-impl-diff.txt
   ```
5. **Run static analysis (aspect-4 input).** Determine round counter
   `n` from existing `.scrum/reviews/static-analysis-r*.json` (next
   integer; first round = `1`):
   ```bash
   ROUND=$(ls .scrum/reviews/static-analysis-r*.json 2>/dev/null \
     | sed -E 's|.*static-analysis-r([0-9]+)\.json|\1|' \
     | sort -n | tail -1)
   ROUND=$(( ${ROUND:-0} + 1 ))
   ```
   Run language tools on the Sprint-wide source path union:
   - Python sources → `ruff check --select F401,F841,ARG,B --output-format json`
   - Shell sources → `shellcheck -f json`
   - (Other languages: skip; reviewer degrades gracefully.)

   Aggregate results into
   `.scrum/reviews/static-analysis-r${ROUND}.json` matching the schema
   in `agents/maintainability-reviewer.md` § Receives. On any tool
   failure, set `tools[].exit_code` to the non-zero code AND keep going
   — do NOT abort the skill.

   If every tool fails OR no source files match a supported language,
   set `skipped_reason` to a short string (e.g. `"no python/shell
   sources in diff"`); the maintainability reviewer will degrade
   accordingly.
6. **Clear stale aspect outputs from prior Sprint.** Reviewer agents
   sometimes read existing `aspect-*.md` files before writing, and
   produce output anchored to the prior Sprint's findings. Delete
   them before spawning so each reviewer starts from a clean slate
   (the per-Sprint round counter `n` only applies to
   `static-analysis-r*.json`; aspect outputs are overwritten in
   place):
   ```bash
   rm -f .scrum/reviews/aspect-requirement-conformance-review.md \
         .scrum/reviews/aspect-functional-quality-review.md \
         .scrum/reviews/aspect-security-review.md \
         .scrum/reviews/aspect-maintainability-review.md \
         .scrum/reviews/aspect-docs-consistency-review.md
   ```
7. **Announce expected duration to the user (mandatory).** Before
   spawning, output a single short notice so the user does not
   interpret silence or `completion-gate.sh` Stop-blocks as failure
   and try to `/clear` the session mid-review. cars_auction_scraping_proto
   retrospectives showed this UX failure 5 Sprints in a row
   (imp-005 / imp-008 / imp-010 / imp-014 / imp-016) before the
   announcement convention was made explicit. Use this exact wording
   so the user learns to recognise it:

   > "Cross-review: 5 アスペクト並列起動します。完了まで 60-120 秒（最大
   > 5 分）。その間 `completion-gate.sh` がセッション終了をブロックします。
   > もし 5 分以上応答がなければここに声をかけてください。"

   Then, and only then, spawn the reviewers in the next step.

8. **Spawn 5 reviewers in parallel** via the `Agent` tool. **No
   per-PBI fan-out — each reviewer receives the whole Sprint.**
   Single `Agent` call per aspect.

   **File ownership reminder (responsibility split).** Aspect
   reviewers are intentionally Read-only (no `Write` tool — see
   `agents/*-reviewer.md` `tools:`). They return the review content
   **as their final assistant message**. The Scrum Master persists
   that message to `.scrum/reviews/aspect-*.md` in Step 9 of this
   skill. Do NOT prompt reviewers to write the file themselves — that
   creates the failure mode logged in kaiten_bot imp-s27 / imp-s29-04
   where reviewers either refuse (Strict Rule "DO NOT modify files")
   or silently do nothing. Tell each reviewer explicitly: "Return the
   review content as your final message; the orchestrator will
   persist it to <path>."

   Inputs and destination file per aspect:
   - `requirement-conformance-reviewer` → `requirements.md`,
     `docs/design/specs/**` (touched), Sprint PBI summary (id, title,
     `acceptance_criteria`, `paths_touched`), Sprint-wide source path
     list, per-PBI `.scrum/pbi/<pbi-id>/design/design.md` (for the
     AC Mapping section) and
     `.scrum/pbi/<pbi-id>/ut/ac-coverage-r{last}.json` (the AC →
     test evidence). SM persists final message to
     `.scrum/reviews/aspect-requirement-conformance-review.md`.
   - `functional-quality-reviewer` → same Sprint summary + source
     list, with explicit reminder that scope is **cross-PBI seams
     only**. SM persists to
     `.scrum/reviews/aspect-functional-quality-review.md`.
   - `security-reviewer` → Sprint-wide source path list +
     `requirements.md`. SM persists to
     `.scrum/reviews/aspect-security-review.md`.
   - `maintainability-reviewer` → Sprint-wide source list +
     `.scrum/reviews/static-analysis-r${ROUND}.json`. SM persists to
     `.scrum/reviews/aspect-maintainability-review.md`.
   - `docs-consistency-reviewer` → `docs/**` +
     `.scrum/reviews/sprint-impl-diff.txt` + Sprint PBI summary. SM
     persists to `.scrum/reviews/aspect-docs-consistency-review.md`.

   Do NOT pass: PBI descriptions, dev communications, `.scrum/`
   pipeline state. (Reviewers 1/2/5 may receive PBI `id` + `title` +
   `paths_touched` only — the minimum needed for PBI-mapping.)

   **Reviewer wait barrier.** After spawning, wait for all 5
   reviewer Tasks to reach `Status = completed`. Do NOT attempt to
   stop the session in between. Reviewer completion typically takes
   60-120s — do NOT interpret a Stop hook block
   (`completion-gate.sh` "PBIs not done") as reviewer failure.
   Persistence to `aspect-*.md` is Step 9's job, after `Status =
   completed` — do NOT wait for the file to appear before Step 9.
   See `agents/scrum-master.md` § Background Subagent + Stop Hook
   Reading.

   **Reviewers are single-shot.** Their `Status = completed` is the
   success signal — do NOT apply the Teammate Liveness Protocol re-spawn
   rule meant for Developer teammates. If a reviewer's final message
   is missing or empty, re-spawn that single reviewer.
9. **Persist aspect reviews.** For each completed reviewer Task,
   read its final assistant message and write it verbatim to the
   per-aspect file under `.scrum/reviews/aspect-<aspect>-review.md`.
   This file ownership lives with the SM (Write tool) — reviewers
   themselves do not have the Write tool by design, so this step is
   not optional. If the reviewer's message is empty / lacks a
   "Verdict:" line, re-spawn that reviewer instead of writing a
   stub.
10. **Build per-PBI digests.** For each Sprint PBI write
   `.scrum/reviews/<pbi-id>-review.md` containing:
   - Header naming the PBI + aspect-verdict matrix (5 cells).
   - Findings filtered to that PBI (a Finding tagged with multiple
     PBIs is **copied to each** — multi-counting is intentional, see
     plan OQ-3 case A).
   - Aggregate verdict for the PBI: PASS only when no aspect 1/2/3
     Critical/High Finding involves it (aspect 4/5 Findings do NOT
     block the PBI; they trigger follow-up PBI generation instead).
11. **Handle FAIL — aspect-specific routing.**
   - **Aspects 1/2/3 (req-conformance / functional-quality /
     security):** for each PBI named in any Critical/High Finding
     under those aspects:
     ```bash
     .scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
     ```
     Then `TaskGet` the PBI's Developer; terminated → re-spawn
     (Teammate Liveness Protocol). Relay the Findings as the fix
     directive. Developer fixes on top of merged code, re-runs PBI
     Review → UT Run → ready-to-merge handoff. SM re-merges; PBI
     returns to `awaiting_cross_review`.
   - **Aspects 4/5 (maintainability / docs-consistency):** for each
     PBI named in any Critical/High Finding under those aspects,
     append a follow-up PBI:
     ```bash
     # dedup guard — skip if a matching follow-up already exists
     TITLE_PREFIX="[cross-review-followup:${PBI_ID}:${ASPECT}]"
     EXISTS=$(jq --arg p "$TITLE_PREFIX" \
       '[.items[] | select(.title | startswith($p))] | length' \
       .scrum/backlog.json)
     if [ "$EXISTS" = "0" ]; then
       .scrum/scripts/add-backlog-item.sh \
         --title "${TITLE_PREFIX} <short summary>" \
         --description "<aspect> follow-up for ${PBI_ID}. See .scrum/reviews/${PBI_ID}-review.md for findings." \
         --parent "${PBI_ID}"
     else
       echo "skip dedup ${TITLE_PREFIX}"
     fi
     ```
     `<aspect>` ∈ `{maintainability, docs-consistency}`. The PBI itself
     is **not** reverted for these aspects.
12. **Re-loop policy.** If any aspect 1/2/3 reverted ≥ 1 PBI to
    `in_progress_impl`, the Sprint is incomplete. Wait for the
    Developer cycle to bring those PBIs back to
    `awaiting_cross_review`, then **re-run the entire skill from
    Step 1** for the affected PBIs (round counter `n` advances;
    static analysis runs again; ALL 5 aspects re-evaluate). Aspect
    4/5 follow-up PBI generation is fire-and-forget — they do NOT
    cause a re-loop.
13. **Mark passing PBIs done.** When no aspect 1/2/3 Critical/High
    Finding remains for a PBI:
    ```bash
    .scrum/scripts/update-backlog-status.sh "$PBI_ID" done
    .scrum/scripts/set-backlog-item-field.sh "$PBI_ID" review_doc_path \
      ".scrum/reviews/${PBI_ID}-review.md"
    ```

Ref: FR-009

## Exit Criteria

- App builds + tests pass (verified before review).
- All 5 aspect reviews ran and persisted to
  `.scrum/reviews/aspect-*.md`.
- Static-analysis run recorded at
  `.scrum/reviews/static-analysis-r{n}.json` (or `skipped_reason`
  populated).
- Per-PBI digest at `.scrum/reviews/<pbi-id>-review.md` exists for
  every Sprint PBI.
- Every Sprint PBI ended at `status: done` (no Critical/High aspect
  1/2/3 Finding survives).
- Aspect 4/5 follow-up PBIs appended to backlog with
  `[cross-review-followup:<pbi-id>:<aspect>]` title prefix and
  `parent_pbi_id` set; no duplicates.
- `items[].review_doc_path` set for every Sprint PBI.
- `state.json` overall phase: `review`.
