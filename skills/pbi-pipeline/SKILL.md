---
name: pbi-pipeline
description: >
  PBI development pipeline — orchestrates design, impl+UT, PBI review,
  and UT-run stages with sub-agent fan-out, file-based handoff, and
  deterministic termination gates (Anthropic + Ralph + GAN-derived).
  Used by Developer per assigned PBI. Replaces former design +
  implementation skills.
disable-model-invocation: false
---

## Inputs

- PBI assignment (backlog.json entry for assigned PBI)
- requirements.md path
- Related catalog specs (read-only references)
- .scrum/config.json
- 6 PBI Pipeline sub-agent definitions (subset of the 11 catalog
  sub-agents verified by install-subagents): `pbi-designer`,
  `pbi-implementer`, `pbi-ut-author`, `codex-design-reviewer`,
  `codex-impl-reviewer`, `codex-ut-reviewer`
- 5 Integrity-stage aspect reviewer definitions (the remaining catalog
  sub-agents), spawned in the per-PBI Integrity stage:
  `requirement-conformance-reviewer`, `functional-quality-reviewer`,
  `security-reviewer`, `maintainability-reviewer`,
  `docs-consistency-reviewer`

## Outputs

- Source code + test code committed to the PBI branch in the PBI
  worktree via `.scrum/scripts/commit-pbi.sh`. Never commit directly
  with raw `git commit`: a raw `git commit -A` would stage the
  `.scrum -> ../../../.scrum` symlink that `create-pbi-worktree.sh`
  installs, and that symlink would then propagate to `main` on the
  per-PBI merge. `commit-pbi.sh` does a two-step `git add -A` then
  `git reset --quiet HEAD -- .scrum` to drop the symlink; only the
  wrapper is safe. (The single-step pathspec form
  `git add -A -- ':!.scrum'` returned rc=1 under git 2.36+ when
  `.scrum` is already gitignored — see `commit-pbi.sh`'s in-file
  comment for the rationale.)
- .scrum/pbi/<pbi-id>/ artifacts (design, reviews, metrics, feedback,
  summaries, pipeline.log, ut/ac-coverage-r{n}.json)
- backlog.json `items[].status` driven via
  `.scrum/scripts/update-backlog-status.sh` (Developer manages the
  `in_progress_*` range; SM owns the rest of the 13-value enum).
- Notification to SM via Agent Teams

## Status range owned by this skill (Developer side)

```
in_progress_design  → in_progress_impl ⇄ in_progress_pbi_review ⇄ in_progress_ut_run → in_progress_merge
                                                                                  → escalated  (any stage; via termination gate)
```

The 8 SM-managed status values (see [docs/data-model.md § State Transitions: status](../../docs/data-model.md#state-transitions-status-13-value-enum-actor-split)) MUST NOT be written by this skill.

## Stages (decision tree)

The flow branches on `backlog.json items[].kind`. Read kind at Init
and pick one of two paths.

```bash
KIND="$(jq -r --arg id "$PBI_ID" '
  (.items[] | select(.id == $id) | .kind) // "code"
' .scrum/backlog.json)"
```

### kind=code (default — full pipeline)

```text
[Init] create .scrum/pbi/<pbi-id>/ + state.json (rounds, *_status)
       update-backlog-status.sh "$PBI_ID" in_progress_design
   ↓
[Design Stage] Rounds 1..5 → see references/design-stage.md
   - status: in_progress_design
   - mandatory library selection web search → design.md Library
     Selection section + S-070 verified library specs (stdlib-only PBI
     records the explicit stdlib-only line)
   ↓ success
[Impl Stage] Rounds 1..5 → see references/impl-ut-stage.md
   - status: in_progress_impl
   - per round: spawn impl + UT in parallel
   ↓
[PBI Review Stage]
   - status: in_progress_pbi_review
   - codex-impl-reviewer + codex-ut-reviewer in parallel
   - aggregate findings; FAIL → status reverts to in_progress_impl
     (next impl round). See [feedback routing](references/feedback-routing.md)
     for how findings/test failures are split between impl and UT agents.
   ↓ PASS
[UT Run Stage]
   - status: in_progress_ut_run
   - real test execution + coverage measurement → see references/coverage-gate.md
   - aggregate Pass criteria; FAIL → status reverts to in_progress_impl
     (next round) OR escalates (termination gate)
   ↓ PASS
[Integrity Stage] → see references/integrity-stage.md
   - runs at the tail of in_progress_ut_run (no own status)
   - 5 aspect reviewers in parallel against THIS PBI's increment
     (requirement-conformance, functional-quality, security,
     maintainability, docs-consistency) + Pass-A static analysis
   - any Critical/High → FAIL → status reverts to in_progress_impl
     (next round via begin-impl-round.sh; impl_round hard cap bounds it)
     OR escalates (termination gate on the union of aspect findings)
   - PASS → conductor writes .scrum/reviews/<pbi-id>-review.md and sets
     review_doc_path (quality-gate DoD)
   ↓ PASS
[Ready-to-merge handoff]
   - run .scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>
     (sets head_sha, paths_touched, ready_at; sets backlog status to
     in_progress_merge)
   - notify SM: "[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<id> sha=<head>"
   - stop and wait for SM SendMessage (MERGED / MERGE_CONFLICT /
     ARTIFACT_MISSING)
```

### kind=docs (Design + UT all skipped)

```text
[Init] create .scrum/pbi/<pbi-id>/ + state.json
       # Skip in_progress_design entirely; mark design/coverage as skipped.
       # ut_status starts pending (begin-impl-round.sh resets it to
       # pending each impl round — the UT *work* is skipped, not the status).
       update-pbi-state.sh "$PBI_ID" \
         design_status skipped ut_status pending coverage_status skipped
       update-backlog-status.sh "$PBI_ID" in_progress_impl
   ↓
[Impl Stage] Rounds 1..5 → see references/impl-ut-stage.md § kind=docs
   - status: in_progress_impl
   - per round: spawn pbi-implementer ONLY (no pbi-ut-author)
   ↓
[PBI Review Stage]
   - status: in_progress_pbi_review
   - codex-impl-reviewer ONLY (no codex-ut-reviewer)
   - docs-shaped review: cross-ref / frontmatter / revision_history /
     semantic match against the parent PBI's findings.
   - aggregate verdict; FAIL → status reverts to in_progress_impl
     (next impl round).
   ↓ PASS
[Integrity Stage]  (aspects 1 + 5 only) → see references/integrity-stage.md
   - runs at the tail of in_progress_pbi_review (no own status)
   - requirement-conformance + docs-consistency reviewers only
   - any Critical/High → FAIL → status reverts to in_progress_impl
     (next impl round) OR escalates (termination gate)
   - PASS → conductor writes .scrum/reviews/<pbi-id>-review.md and sets
     review_doc_path
   ↓ PASS
[Ready-to-merge handoff]  (UT Run stage skipped)
   - mark-pbi-ready-to-merge.sh enforces paths_touched ⊆ **/*.md;
     violation → escalation_reason=kind_mismatch.
   - notify SM identically to the kind=code path.
```

The `paths_touched ⊆ **/*.md` boundary is machine-enforced by
`mark-pbi-ready-to-merge.sh` (PR-1). The conductor itself does not
re-validate — a `kind_mismatch` escalation is the wrapper's response
to a docs PBI that touched non-.md, which means either refinement
mis-classified the PBI or the implementer scope-crept. Either way,
the SM owns the decision.

## Sub-agents spawned

See `references/sub-agent-prompts.md` for full input prompt templates.

- `pbi-designer` — Design Round Step 1 (sequential)
- `codex-design-reviewer` — Design Round Step 2 (sequential)
- `pbi-implementer` ‖ `pbi-ut-author` — Impl Round Step 1 (parallel pair)
- `codex-impl-reviewer` ‖ `codex-ut-reviewer` — PBI Review Stage (parallel pair)
- `requirement-conformance-reviewer` ‖ `functional-quality-reviewer` ‖
  `security-reviewer` ‖ `maintainability-reviewer` ‖
  `docs-consistency-reviewer` — Integrity Stage (parallel barrage;
  kind=code all 5, kind=docs aspects 1 + 5 only). These are
  Claude-backed (`model: opus`) and message-based — no codex preflight,
  no `Write` tool; the conductor consolidates their returned messages.
  functional-quality and security internally add a codex second opinion
  (adjudicated, non-fatal on codex absence) — invisible to the
  conductor. See `references/integrity-stage.md`.

**Every Agent spawn in this pipeline is synchronous — pass
`run_in_background: false`.** A background spawn parks the conductor:
nothing re-invokes it when the sub-agent finishes, and the Round
handoff sits until an SM nudge (a target project logged a >10-hour
stall at an impl→UT handoff). "Wait for both to return" in the stage
references means the synchronous call itself — never a hand-rolled
poll loop (see `references/reviewer-stall-fallback.md` § Bounded
waiting for why spinning is forbidden).

**Producer containment.** The three producer prompts (designer /
implementer / ut-author) each carry a `{worktree_path}` slot with an
absolute-path write rule, and the conductor verifies after every
producer round that the main checkout gained no new dirt — see
`references/worktree-containment.md` for the snapshot/relocate
procedure. Leaks recurred across 11 Sprints in a target project when
this was prompt-discipline only.

All three `codex-*-reviewer` spawns share the stall fallback protocol
in `references/reviewer-stall-fallback.md` (post-return persistence check →
single general-purpose-agent retry → escalate as `reviewer_unavailable`;
Explore is unusable here — it has no `Write` tool to persist the
review file).

All three also share a snapshot-pin contract. The conductor captures
pins immediately before spawn and passes them as input slots:

- design reviewer: `{design_hash}` (SHA-256 of design.md)
- impl + UT reviewers: `{worktree_path}`, `{review_sha}`
  (`git rev-parse HEAD` of `pbi/<id>` after `commit-pbi.sh`), and
  `{design_hash}`

Reviewers verify pins as their FIRST action and emit a
`stale_snapshot:` error envelope on mismatch (no review file
written). On PASS/FAIL the review file MUST begin with header lines
`Reviewed-Head: <sha>` (impl/UT) and `Reviewed-Design-Hash: <hash>`.
The conductor verifies these headers after reading each review file;
mismatch / `stale_snapshot:` error → one respawn with refreshed pins
→ escalate `stale_review_snapshot`. See `references/design-stage.md`
and `references/impl-ut-stage.md` for the full conductor procedure.

## State management

PBI internal state: `.scrum/pbi/<pbi-id>/state.json` (round counters,
per-stage `*_status` flags). Backlog status is the SSOT for stage
position; state.json holds internal mechanics only. See
`references/state-management.md` for schema and write helpers.

## Parallel PBI coordination

Catalog write contention: see `references/catalog-contention.md`
(3-layer defense: sprint planning pre-separation + flock + mtime check).

## Escalation

When a termination gate triggers escalation, set backlog status to
`escalated` via `update-backlog-status.sh`, write
`escalation_reason` into state.json via `update-pbi-state.sh`, and
notify SM via Agent Teams. SM handles via the
`pbi-escalation-handler` skill.

See [termination gates](references/termination-gates.md) for the
composite gate matrix (success / stagnation / divergence / hard cap)
evaluated at end of each Round.

## Exit Criteria

- backlog.json `items[].status ∈ {in_progress_merge, escalated}`
- For `in_progress_merge`: `state.json.head_sha` and `paths_touched`
  populated, `ready_at` set
- For `escalated`: `state.json.escalation_reason` populated
- SM notified
