---
name: cross-review
description: >
  Sprint-end cross-cutting quality gate. Scrum Master runs static analysis,
  then spawns 5 aspect-specialized reviewers PLUS 3 whole-repo
  codebase-audit axes in one parallel barrage (8 agents; each aspect
  reviews the whole Sprint, each audit axis the whole repo at HEAD). FAIL
  routing is aspect-specific: aspects 1-3 revert PBIs to in_progress_impl,
  aspects 4-5 generate follow-up PBIs. Audit findings are non-blocking —
  Critical/High become draft PBIs for the next Sprint (separate report).
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
slices, and assumes per-PBI Pass criteria are already satisfied
(prior context in `.scrum/pbi/<pbi-id>/impl/review-r{last}.md` and
`ut/review-r{last}.md`). PBI mapping is recorded inside Findings via
reverse-lookup against `paths_touched`.

Composed onto this, the same ceremony spawns the 3 **whole-repo**
`codebase-audit` axes in the same parallel barrage (Step 8) and
synthesizes them separately (Step 14). The audit scans the accumulated
codebase at HEAD — a scope the 5 diff-oriented aspects cannot reach —
and is **non-blocking**: its findings become draft PBIs for the next
Sprint and never affect this Sprint's PASS/FAIL. The 5-aspect verdict
machinery below is unchanged. See `skills/codebase-audit/SKILL.md`.

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
- `.scrum/reviews/codebase-audit-s{N}.md` — the separate whole-repo
  audit report (Step 14; does NOT feed the aspect digest matrix)
- Draft `[codebase-audit:*]` PBIs for the **next** Sprint (Step 14;
  non-blocking, Critical/High mandatory)
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
   The analysis runs in **two passes** whose findings both land in the
   single `.scrum/reviews/static-analysis-r${ROUND}.json` file (one
   `tools[]` entry per tool invocation, from either pass).

   **Pass A — intra-file lint (Sprint-diff scope).** Run on the
   Sprint-wide source path union (files this Sprint touched):
   - Python sources → `ruff check --select F401,F841,ARG,B --output-format json`
   - Shell sources → `shellcheck -f json`
   - (Other languages: skip; reviewer degrades gracefully.)

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
   `.scrum/reviews/static-analysis-r${ROUND}.json` matching the schema
   in `agents/maintainability-reviewer.md` § Receives. `ruff` and
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
   configured"`); the maintainability reviewer will degrade
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
   and try to `/clear` the session mid-review. Target-project
   retrospectives showed this UX failure 5 Sprints in a row before the
   announcement convention was made explicit. Use this exact wording
   so the user learns to recognise it:

   > "Cross-review: 5 アスペクト + コードベース監査 3 軸を並列起動します
   > （計 8 エージェント）。完了まで 60-120 秒（最大 5 分）。その間
   > `completion-gate.sh` がセッション終了をブロックします。もし 5 分以上
   > 応答がなければここに声をかけてください。"

   Then, and only then, spawn the reviewers in the next step.

8. **Spawn 5 aspect reviewers + 3 codebase-audit axes in parallel**
   via the `Agent` tool — one barrage, 8 agents. **No per-PBI fan-out
   — each aspect reviewer receives the whole Sprint; each audit axis
   receives the whole repo at HEAD.** Single `Agent` call per aspect
   and per axis.

   **PBI kind partition (prerequisite).** Before spawning, partition
   the Sprint's `cross_review` PBIs by kind. Aspects 2/3/4 evaluate
   runtime / source-code concerns and have nothing to inspect when a
   PBI only touched `*.md`; passing docs PBIs to those reviewers
   produces noise findings and wastes a reviewer slot. Aspects 1 and 5
   still receive every PBI (requirement conformance and
   docs-consistency apply to all changes regardless of kind).

   ```bash
   SPRINT_ID="$(jq -r '.id' .scrum/sprint.json)"
   CODE_PBIS="$(jq -r --arg s "$SPRINT_ID" '
     .items[]
     | select(.sprint_id == $s and .status == "cross_review")
     | select((.kind // "code") == "code")
     | .id
   ' .scrum/backlog.json)"
   DOCS_PBIS="$(jq -r --arg s "$SPRINT_ID" '
     .items[]
     | select(.sprint_id == $s and .status == "cross_review")
     | select((.kind // "code") == "docs")
     | .id
   ' .scrum/backlog.json)"
   CODE_COUNT="$(printf '%s\n' "$CODE_PBIS" | grep -c .)"
   ```

   If `CODE_COUNT == 0` (the entire Sprint is docs-only), skip
   spawning aspects 2/3/4 entirely and write empty `aspect-*.md` stubs
   stating "Skipped: Sprint contains no kind=code PBI". Continue with
   aspects 1 and 5.

   **File ownership reminder (responsibility split).** Aspect
   reviewers are intentionally Read-only (no `Write` tool — see
   `agents/*-reviewer.md` `tools:`). They return the review content
   **as their final assistant message**. The Scrum Master persists
   that message to `.scrum/reviews/aspect-*.md` in Step 9 of this
   skill. Do NOT prompt reviewers to write the file themselves — that
   creates the failure mode logged in target-project retrospectives
   where reviewers either refuse (Strict Rule "DO NOT modify files")
   or silently do nothing. Tell each reviewer explicitly: "Return the
   review content as your final message; the orchestrator will
   persist it to <path>."

   Inputs and destination file per aspect (kind-filtered):
   - `requirement-conformance-reviewer` → `requirements.md`,
     `docs/design/specs/**` (touched), Sprint PBI summary for **all
     PBIs** in `cross_review` (id, title, `acceptance_criteria`,
     `paths_touched`, **kind**), Sprint-wide source path list (code
     PBIs only), per-PBI `.scrum/pbi/<pbi-id>/design/design.md` (code
     PBIs only — docs PBIs have no design doc) and
     `.scrum/pbi/<pbi-id>/ut/ac-coverage-r{last}.json` (code PBIs only
     — docs PBIs have no AC coverage map). For docs PBIs, the reviewer
     judges AC by reading the modified passage; the prompt MUST
     explicitly forbid grep-pattern hit count as a substitute for
     comprehension. SM persists final message to
     `.scrum/reviews/aspect-requirement-conformance-review.md`.
   - `functional-quality-reviewer` → Sprint summary for **code PBIs
     only** + Sprint-wide source path list, with explicit reminder
     that scope is **cross-PBI seams only**. SM persists to
     `.scrum/reviews/aspect-functional-quality-review.md`.
   - `security-reviewer` → Sprint-wide source path list (**code PBIs
     only**) + `requirements.md`. SM persists to
     `.scrum/reviews/aspect-security-review.md`.
   - `maintainability-reviewer` → Sprint-wide source list (**code
     PBIs only**) + `.scrum/reviews/static-analysis-r${ROUND}.json`.
     SM persists to
     `.scrum/reviews/aspect-maintainability-review.md`.
   - `docs-consistency-reviewer` → `docs/**` +
     `.scrum/reviews/sprint-impl-diff.txt` + Sprint PBI summary for
     **all PBIs** (kind included so docs PBIs can be cross-checked
     against their parent PBI's findings). SM persists to
     `.scrum/reviews/aspect-docs-consistency-review.md`.

   Do NOT pass: PBI descriptions, dev communications, `.scrum/`
   pipeline state. (Reviewers 1/2/5 may receive PBI `id` + `title` +
   `paths_touched` + `kind` + `parent_pbi_id` only — the minimum
   needed for PBI-mapping and docs parent linkage.)

   **Codebase-audit axes (3 additional agents in the same barrage).**
   Alongside the aspect reviewers, spawn the 3 whole-repo audit axes
   (`spec-conformance`, `logic-defect`, `redundancy`) per
   `skills/codebase-audit/SKILL.md` context (a) +
   `skills/codebase-audit/references/axes.md`. These are **not**
   kind-partitioned — each scans the entire repo at HEAD (not the
   Sprint diff), so they always run (all 3), even on a docs-only
   Sprint. Feed them the Step 5 static-analysis file
   (`.scrum/reviews/static-analysis-r${ROUND}.json`) as the redundancy
   axis's ground truth, plus the enabled specs, `requirements.md`, and
   the PBI summary. Like the aspect reviewers, audit axes are read-only
   and return findings **as their final message**; the SM synthesizes
   them into the separate audit report in Step 14 (they do **not** feed
   the 5-aspect digest matrix or the Sprint verdict).

   **Wait barrier.** After spawning, wait for **all** Tasks to reach
   `Status = completed`: the aspect reviewers (3 or 5 depending on
   `CODE_COUNT`) **plus the 3 audit axes** — 6 or 8 total. Do NOT
   attempt to stop the session in between. Completion typically takes
   60-120s — do NOT interpret a Stop hook block (`completion-gate.sh`
   "PBIs not done") as a failure. Persistence to `aspect-*.md` is Step
   9's job and audit synthesis is Step 14's job, both after `Status =
   completed` — do NOT wait for any file to appear before those steps.
   See `agents/scrum-master.md` § Background Subagent + Stop Hook
   Reading.

   **Reviewers are single-shot.** Their `Status = completed` is the
   success signal — do NOT apply the Teammate Liveness Protocol re-spawn
   rule meant for Developer teammates. If a reviewer's final message
   is missing or empty, re-spawn that single reviewer.
9. **Persist aspect reviews.** For each completed reviewer Task,
   read its final assistant message and write it verbatim to the
   per-aspect file under `.scrum/reviews/aspect-<aspect>-review.md`.
   The SM has no `Write` tool (Delegate mode — see
   `agents/scrum-master.md` `disallowedTools:`), so persist via a
   Bash heredoc/redirect (`cat > .scrum/reviews/aspect-<aspect>-review.md
   <<'EOF' … EOF`). `.scrum/reviews/` is an artifact directory carved
   out of the scrum-state guard, so direct writes there — both the
   `.md` digests and `static-analysis-r{n}.json` (Step 5) — are
   permitted. This file ownership lives with the SM — reviewers
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
     # Place the per-PBI digest where the Developer's next impl Round
     # will read it as feedback. `begin-impl-round.sh` (called by the
     # Developer at re-entry) doesn't know `n` yet, so use a
     # Round-independent path.
     cp ".scrum/reviews/${PBI_ID}-review.md" \
        ".scrum/pbi/${PBI_ID}/feedback/from-cross-review.md"
     .scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
     ```
     Then `TaskGet` the PBI's Developer; terminated → re-spawn
     (Teammate Liveness Protocol). Relay the Findings as the fix
     directive. Developer re-enters `pbi-pipeline` →
     `begin-impl-round.sh` advances `impl_round` atomically (the
     Round counter is owned by that wrapper; the Developer never
     computes `n+1`). Developer fixes on top of merged code, re-runs
     PBI Review → UT Run → ready-to-merge handoff. SM re-merges; PBI
     returns to `awaiting_cross_review`.
   - **Aspects 4/5 (maintainability / docs-consistency):** for each
     PBI named in any Critical/High Finding under those aspects,
     append a follow-up PBI. **The `--ac` flag is mandatory** — past
     follow-up PBIs created without AC required inline rework at
     Sprint Planning in a target project.

     **Docs-consistency loop guard.** Before generating a
     `docs-consistency` follow-up, walk the PBI's ancestor chain
     (`parent_pbi_id` recursively) and count how many ancestors are
     themselves `[cross-review-followup:*:docs-consistency]` PBIs. If
     the chain already contains 2 such docs-consistency follow-ups,
     the docs problem is not converging by adding another doc PBI on
     top — the parent's findings are likely ambiguous or the
     requirement itself is unclear. Escalate to a human instead of
     looping:

     ```bash
     LOOP_DEPTH=0
     ANC="${PBI_ID}"
     for _ in 1 2 3 4 5; do
       ANC="$(jq -r --arg id "$ANC" '
         .items[] | select(.id == $id) | .parent_pbi_id // empty
       ' .scrum/backlog.json)"
       [ -z "$ANC" ] && break
       TITLE="$(jq -r --arg id "$ANC" '
         .items[] | select(.id == $id) | .title
       ' .scrum/backlog.json)"
       case "$TITLE" in
         *"[cross-review-followup:"*":docs-consistency]"*)
           LOOP_DEPTH=$((LOOP_DEPTH + 1))
           ;;
       esac
     done
     if [ "$ASPECT" = "docs-consistency" ] && [ "$LOOP_DEPTH" -ge 2 ]; then
       printf >&2 'docs-consistency loop for %s (ancestor depth=%d) — escalating instead of generating another follow-up\n' "$PBI_ID" "$LOOP_DEPTH"
       .scrum/scripts/update-pbi-state.sh "$PBI_ID" \
         escalation_reason requirements_unclear
       .scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
       # Skip the add-backlog-item.sh block below for this PBI
       continue
     fi
     ```

     **Opus override for follow-up AC drafting (mandatory).** Same
     reasoning as `skills/backlog-refinement/SKILL.md` § Step 3b
     Opus override: the SM main loop running on Sonnet has produced
     AC-empty or coverage-thin follow-up PBIs that re-fail cross-review
     in the next Sprint. Delegate follow-up AC drafting to an
     Opus-backed sub-agent via the `Agent` tool before invoking
     `add-backlog-item.sh`:

     ```
     Agent({
       subagent_type: "general-purpose",
       model: "opus",
       description: "Follow-up PBI AC drafting",
       prompt: <<<EOF
         Draft acceptance_criteria for a cross-review follow-up PBI.

         Inputs:
         - Parent PBI id, title, paths_touched, kind
         - Aspect: maintainability | docs-consistency
         - Findings (Critical/High only) from the per-PBI digest
         - Per-PBI digest path: .scrum/reviews/<pbi-id>-review.md

         Constraints:
         - Each AC is independently verifiable (Given/When/Then or
           measurable assertion).
         - Cover normal-path + at least one failure / regression-prevention
           check.
         - docs-consistency follow-up: AC MUST describe semantic
           changes ("§X states the new constraint and the rationale";
           "frontmatter related_pbis includes pbi-NNN"). DO NOT
           formulate AC as bare `grep` hit counts — those generate
           empty UT artifacts and don't verify content semantics. This
           is enforced by `backlog-refinement` Check 5 on the next
           refinement pass; pre-flag it here so the refinement audit
           passes first try.
         - maintainability follow-up: AC must reference the specific
           static-analysis rule (ruff/shellcheck code) or the named
           Finding from the digest.

         Output: JSON
           {
             "title_summary": "<short summary for the follow-up>",
             "ac": ["<criterion 1>", "<criterion 2>", ...]
           }
       EOF
     })
     ```

     Then invoke the wrapper with `--ac` and `--kind` flags built from
     the aspect:
     ```bash
     # dedup guard — skip if a matching follow-up already exists
     TITLE_PREFIX="[cross-review-followup:${PBI_ID}:${ASPECT}]"
     EXISTS=$(jq --arg p "$TITLE_PREFIX" \
       '[.items[] | select(.title | startswith($p))] | length' \
       .scrum/backlog.json)
     if [ "$EXISTS" = "0" ]; then
       # docs-consistency follow-ups inherit kind=docs (they only edit
       # .md files); maintainability follow-ups default to code.
       case "$ASPECT" in
         docs-consistency) KIND_FLAG="--kind docs" ;;
         maintainability)  KIND_FLAG="--kind code" ;;
       esac
       # build --ac arguments from the Opus JSON output above
       AC_ARGS=()
       while IFS= read -r line; do AC_ARGS+=(--ac "$line"); done < <(
         jq -r '.ac[]' <<<"$OPUS_JSON"
       )
       SUMMARY=$(jq -r '.title_summary' <<<"$OPUS_JSON")
       # shellcheck disable=SC2086  # KIND_FLAG is two whitespace-separated tokens
       .scrum/scripts/add-backlog-item.sh \
         --title "${TITLE_PREFIX} ${SUMMARY}" \
         --description "<aspect> follow-up for ${PBI_ID}. See .scrum/reviews/${PBI_ID}-review.md for findings." \
         --parent "${PBI_ID}" \
         $KIND_FLAG \
         "${AC_ARGS[@]}"
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
14. **Whole-repo audit synthesis (independent, non-blocking).** The 3
    audit axes spawned in Step 8 are independent of the 5-aspect
    verdict — synthesize them per `skills/codebase-audit/SKILL.md`
    context (a), Steps 3–5:
    - Read the 3 axis final messages, dedup within the audit, and write
      the report to `.scrum/reviews/codebase-audit-s{N}.md`
      (`N` = numeric sprint number).
    - **Cross-reference aspect-4.** A tool-grounded dead-code item
      surfaced by **both** the `maintainability` aspect (Step 11 aspect-4
      follow-up) and the `redundancy` audit axis is one problem — count
      it once, cross-ref the aspect-4 Finding in the audit report, and
      do NOT file a second audit PBI for it.
    - Route Critical/High findings to the **next** Sprint as draft PBIs
      (`[codebase-audit:<sprint-id>:F<n>:<Severity>]`), with the
      cross-Sprint content dedup (skip if an open PBI already tracks the
      finding's `identity`; `[REGRESSION]` if a closed one recurred);
      Medium/Low at PO discretion. This does **not** revert any PBI,
      re-loop the Sprint, or transition the phase — the audit is
      strictly non-blocking here. Full rules + the dedup `jq` in
      `skills/codebase-audit/SKILL.md`.

    On an aspect 1/2/3 re-loop (Step 12), this step is reached only on
    the terminal (non-re-looping) pass; the audit's own dedup makes any
    intermediate re-run idempotent.

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
- Whole-repo audit synthesized to
  `.scrum/reviews/codebase-audit-s{N}.md`; its Critical/High findings
  filed as `[codebase-audit:*]` draft PBIs for the next Sprint (or
  deduped against an existing open one), cross-referenced against
  aspect-4 to avoid double-filing. Audit findings did NOT affect the
  Sprint PASS/FAIL verdict.
