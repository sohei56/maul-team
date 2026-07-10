---
name: codebase-audit
description: >
  Whole-repo, multi-agent audit run as a mandatory gate BEFORE the
  Integration Sprint. The Scrum Master spawns 3 read-only auditors in
  parallel (spec-conformance, logic/defect hunt, redundancy) over the
  ACCUMULATED codebase at HEAD — not the Sprint diff — then dedups,
  severity-classifies, and reports. Critical/High findings become
  draft defect PBIs and route the team back to the defect-fix loop
  before integration testing proceeds.
disable-model-invocation: false
---

## Role

Per-PBI review sees one PBI's diff; Sprint-end `cross-review` sees one
Sprint's diff. Neither can see defects that only emerge in the
**accumulated whole**: dead code that is also an unimplemented
requirement, an I/O default that silently disables a feature, a silent
failure in the wiring layer, two design specs mandating contradictory
behavior, or the same logic implemented twice across PBIs from
different Sprints. Those defects survive every diff-scoped gate and
first surface in the Integration Sprint — the most expensive place to
find them.

This skill closes that structural gap with a **whole-repo audit at
HEAD**, run once as a pre-flight gate to the `integration-tests` skill.
It is SM-owned and read-only: auditors read and reason, they never
edit. Findings that matter become draft PBIs and the team fixes them in
a normal development loop before the Integration Sprint starts.

The audit runs along three evidence-based axes, each a single
parallel auditor via the `Agent` tool:

| Axis | Focus | What only this axis catches |
|---|---|---|
| `spec-conformance` | Implementation vs enabled specs + requirements | Divergences, coded-but-unspecified behavior (dead code that is also a spec gap), and spec-vs-spec conflicts |
| `logic-defect` | I/O orchestration + wiring layer | Feature-disabling production defaults, boundaries unit tests mock out, silent failures, edge cases in scheduling / state transitions |
| `redundancy` | Dead code, cross-PBI duplication, stale docs | Unused exports, duplicate implementations of the same logic across PBIs, docstrings that no longer match the code |

## Inputs

- `.scrum/state.json` — phase (`integration_sprint` on entry, or the
  phase from which the SM launched this gate).
- `.scrum/sprint.json` — `id` (drives the report filename) and
  `base_sha` (context only; the audit scope is HEAD, **not** a diff).
- `.scrum/backlog.json` — all PBIs (`id`, `title`,
  `acceptance_criteria`, `kind`) for the spec-conformance axis to map
  requirements to implementation, and for cross-PBI duplication
  reasoning.
- `docs/requirements.md` — the requirement SSOT.
- `docs/design/catalog-config.json` — the `enabled` array of spec IDs
  (SSOT for which specs are in scope).
- `docs/design/specs/**` — enabled spec files (per
  `docs/design/catalog.md`, each at
  `docs/design/specs/{category}/{id}-{slug}.md`).
- `.scrum/po/decisions.json` — the PO decision log. The
  spec-conformance axis checks it for an adjudication **before**
  flagging a spec-vs-spec conflict (an already-decided conflict is not
  a finding).
- `.scrum/reviews/static-analysis-r*.json` — most recent
  `cross-review` static-analysis output, when present. The redundancy
  axis cites it as ground truth for unused symbols; absent, it falls
  back to reachability reasoning at explicitly lower confidence.
- Project source code + test suites (whole repo at HEAD).

## Outputs

- `.scrum/reviews/codebase-audit-s{N}.md` — the single synthesized
  audit report (`N` = the numeric sprint number from `sprint.json.id`,
  e.g. `codebase-audit-s3.md` for `sprint-003`). Deduped findings,
  each with axis, severity, `file:line`, evidence, and fact-vs-
  interpretation separated.
- Draft defect PBIs in `.scrum/backlog.json` via
  `.scrum/scripts/add-backlog-item.sh` — one per Critical/High finding
  (mandatory); Medium/Low at PO discretion. Title prefix
  `[codebase-audit:<sprint-id>:F<n>]` for dedup.
- On a Critical/High gate trip routed to the defect-fix loop:
  `state.json` phase → `backlog_created` via
  `.scrum/scripts/update-state-phase.sh`.
- A completion report to the user / PO (gate verdict + severity
  counts + PBIs created).

## Preconditions

- ≥1 Development Sprint has completed (there is accumulated code to
  audit). This gate is meaningless on an empty repo.
- `requirements.md` and the enabled design specs exist.
- The team is at the Integration Sprint boundary — either the SM is
  running this directly, or `integration-tests` invoked it as its
  pre-flight step.

## PO Mode (po_mode: "agent")

When `.scrum/config.json.po_mode == "agent"`, the PO seat is the
`product-owner` teammate, not the human. The ceremony shape is
unchanged; only the destination of the gate decision is re-targeted.
Every "ask the user" / "user decides" phrase in the Steps below is
mode-agnostic — under `po_mode=agent` it resolves to a
`PO_DECISION_REQUEST` and its `PO_DECISION` reply per
`rules/scrum-context.md` § PO seat resolution; **do not branch the
flow on mode.** The SM never blocks on `read` from stdin in this mode.

| Step | Override (po_mode=agent) |
|------|--------------------------|
| 6. Gate decision | Replace "ask the user whether to route back to the defect-fix loop" with `[sprint-<N>] PO_DECISION_REQUEST kind=defect_triage options=[fix_now,defer,reject] recommendation=fix_now` carrying the full Critical/High finding list. The PO returns a route per finding in a single reply; no per-finding round-trip, no human-input wait. Medium/Low PBI creation follows the same reply. |

Informational lines ("report the verdict to the user") are
observation-only — emit the summary, do not wait for a reply.

## Steps

1. **Resolve scope and check for resume.**
   ```bash
   SPRINT_ID="$(jq -r '.id' .scrum/sprint.json)"   # e.g. sprint-003
   N="$((10#${SPRINT_ID#sprint-}))"                 # 3
   REPORT=".scrum/reviews/codebase-audit-s${N}.md"
   mkdir -p .scrum/reviews
   ```
   **Idempotence / resume.** If `$REPORT` already exists for the
   current sprint:
   - If it is **gate-clean** (no open Critical/High finding), reuse it
     — report that you are reusing the existing audit and skip to Step
     7 (proceed). Do **not** re-run.
   - If it carries open Critical/High findings, you are resuming an
     interrupted run; re-run the audit fresh (Steps 2–6 overwrite
     `$REPORT`) to re-verify against current HEAD.

   A fresh Integration-Sprint re-entry after a defect-fix loop always
   has a new sprint number, so its `$REPORT` does not exist yet and the
   audit runs from scratch against the fixed code — this is intended.

2. **Assemble the shared read set.** Collect for the auditors:
   - Enabled spec IDs from `docs/design/catalog-config.json` and their
     files under `docs/design/specs/**`.
   - `docs/requirements.md`.
   - The PBI summary (`id`, `title`, `acceptance_criteria`, `kind`)
     from `backlog.json`.
   - The most recent static-analysis file, if any:
     ```bash
     STATIC="$(ls .scrum/reviews/static-analysis-r*.json 2>/dev/null \
       | sort -V | tail -1)"
     ```
   Do NOT pass `.scrum/` pipeline state, dev communications, or PBI
   descriptions beyond the fields above.

3. **Announce expected duration to the user (mandatory).** Whole-repo
   auditors take longer than diff-scoped reviewers. Emit one short
   notice so the user does not read silence or a `completion-gate.sh`
   Stop-block as failure:

   > "Codebase audit: 3 アスペクトを並列起動します（リポジトリ全体走査）。
   > 完了まで数分かかります。その間 `completion-gate.sh` がセッション終了
   > をブロックします。5 分以上応答がなければ声をかけてください。"

4. **Spawn the 3 auditors in parallel** via the `Agent` tool — one
   `Agent` call per axis, `run_in_background: true`, in a single
   message. Each receives the common protocol plus its axis prompt
   from [`references/axes.md`](references/axes.md), and the shared read
   set from Step 2. Auditors are **read-only** and return their
   findings **as their final assistant message** (structured per the
   finding schema in `references/axes.md`); the SM synthesizes and
   persists in Step 5 — do not ask auditors to write the report file.

   Wait for all 3 auditor Tasks to reach `Status = completed`. Do NOT
   attempt to end the session in between; a Stop-hook block during the
   wait is not a failure. Auditors are single-shot — `Status =
   completed` is the success signal; re-spawn only a single auditor
   whose final message is missing or empty (do not apply the Developer
   Teammate Liveness re-spawn rule).

   After each auditor completes, `git status` must be clean — read-only
   is enforced by prompt only. If an auditor left the tree dirty,
   discard its edits and re-run it.

5. **Synthesize + dedup + classify.** Read the 3 auditors' findings
   and produce the single report at `$REPORT` (persist via a Bash
   heredoc — `.scrum/reviews/` is carved out of the scrum-state guard,
   so direct writes there are permitted; the SM has no `Write` tool):
   - **Dedup:** the same underlying defect surfaced by two axes counts
     **once** (e.g. dead code flagged by both `spec-conformance` and
     `redundancy`). Keep the higher severity and note both axes.
   - **Severity** (see definitions below) per distinct finding.
   - Number findings `F1..Fn`. Each carries: axis(es), severity,
     `file:line`, evidence (fact), interpretation (labeled separately),
     and a one-line proposed fix / AC.
   - Report structure: headline (total findings, Critical/High count,
     gate verdict) → severity-sorted finding table → per-finding detail
     → the derived PBI list.

   **Severity definitions:**
   | Severity | Definition |
   |---|---|
   | **Critical** | Breaks a core acceptance criterion, corrupts or silently drops data on a production path, or a spec-vs-spec conflict that makes correct behavior undefined. |
   | **High** | Feature-disabling production default, unhandled failure on a primary path, a spec divergence that changes observable behavior, or a cross-PBI duplicate implementation that will drift out of sync. |
   | **Medium** | Dead code / unused export, an edge-case gap on a secondary path, or a stale docstring/comment that actively misleads. |
   | **Low** | Cosmetic redundancy or comment drift with no behavioral or maintenance risk. |

6. **Gate decision + PBI creation.**
   - **Any Critical/High finding** → this is a gate trip. Present the
     Critical/High list and **ask the user** whether to route back to
     the defect-fix loop before the Integration Sprint proceeds
     (recommended: yes — that is the point of the gate). Under
     `po_mode=agent` this resolves to the `defect_triage`
     `PO_DECISION_REQUEST` in the PO Mode table above.
     - Create **one draft PBI per Critical/High finding** (mandatory),
       with a dedup guard:
       ```bash
       for Fn in <critical_high_finding_ids>; do
         PREFIX="[codebase-audit:${SPRINT_ID}:${Fn}]"
         EXISTS="$(jq --arg p "$PREFIX" \
           '[.items[] | select(.title | startswith($p))] | length' \
           .scrum/backlog.json)"
         if [ "$EXISTS" = "0" ]; then
           .scrum/scripts/add-backlog-item.sh \
             --title "${PREFIX} <short summary>" \
             --description "Codebase-audit finding ${Fn}. See ${REPORT}." \
             --ac "<expected vs actual, independently verifiable>" \
             --kind <code|docs>
         fi
       done
       ```
       Each AC states expected vs actual and is independently
       verifiable — never a bare `grep` hit count. Set `--kind docs`
       only when the finding is confined to `**/*.md`; otherwise
       `code`.
     - On the route-back decision, transition to the defect-fix loop:
       ```bash
       .scrum/scripts/update-state-phase.sh backlog_created
       ```
       The team runs a normal development Sprint over the new defect
       PBIs, then re-enters the Integration Sprint (a fresh audit runs
       against the fixed HEAD — see Step 1). **Do not** proceed to
       test derivation on a tripped gate.
   - **Medium/Low findings** → at PO discretion. Offer to create PBIs;
     create those the PO/user approves with the same prefix + dedup
     guard. Medium/Low alone does **not** trip the gate.

7. **Proceed (gate clean).** When no Critical/High finding remains
   (or the report was reused as gate-clean in Step 1), report the
   verdict to the user/PO and hand back to the caller. If invoked as
   the `integration-tests` pre-flight, `integration-tests` continues
   with test derivation. This skill does **not** transition to any
   downstream phase itself — a clean gate leaves the phase untouched.

## Strict Rules

- **Read-only.** Auditors never edit code, docs, specs, or state.
  Implementation happens later as normal PBI work. Verify `git status`
  is clean after each auditor.
- **Whole-repo scope.** The audit target is the accumulated codebase
  at HEAD, not any Sprint or PBI diff. `base_sha` is context only.
- **No fix without a PBI.** Every actioned finding becomes a draft PBI
  through `.scrum/scripts/add-backlog-item.sh` — never a direct edit,
  never a raw `jq` write to `backlog.json`.
- **Fact vs interpretation stay separated** in every finding. "`fetch`
  passes no cursor param (`client.py:88`)" is a fact; "pagination is
  probably broken" is interpretation.
- **Spec-vs-spec conflicts check the PO decision log first.** A
  conflict already adjudicated in `.scrum/po/decisions.json` is not a
  finding.
- **Redundancy claims are grounded.** Cite the static-analysis file
  when it exists; otherwise state the reachability reasoning and mark
  the finding lower-confidence. Never assert "unused" from a single
  grep with no reachability argument.
- **A gate trip is not overridden silently.** Critical/High findings
  route through the PO gate decision; the SM does not wave the
  Integration Sprint through on its own authority.

## Exit Criteria

- `.scrum/reviews/codebase-audit-s{N}.md` exists for the current
  sprint, with all 3 axes represented, findings deduped and
  severity-classified, and fact separated from interpretation.
- Every Critical/High finding has a corresponding draft PBI in
  `backlog.json` (with the `[codebase-audit:<sprint-id>:F<n>]` prefix)
  — or an explicit PO decision recorded to defer/reject it.
- Gate resolved: either **clean** (no Critical/High → handed back to
  the caller, phase untouched) or **tripped** (Critical/High → defect
  PBIs created and phase set to `backlog_created`).
- `git status` clean (auditors made no edits).

## References

- [`references/axes.md`](references/axes.md) — common auditor protocol,
  the finding-return schema, and the 3 axis prompt templates.

Ref: FR-013 (Integration Sprint). The pre-flight gate itself is a
framework-level quality mechanism, not an FR-013 mandate.
