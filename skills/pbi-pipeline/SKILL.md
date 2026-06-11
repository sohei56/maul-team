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

## Outputs

- Source code + test code committed to the PBI branch in the PBI
  worktree via `.scrum/scripts/commit-pbi.sh`. Never commit directly
  with raw `git commit`: a raw `git commit -A` would stage the
  `.scrum -> ../../../.scrum` symlink that `create-pbi-worktree.sh`
  installs, and that symlink would then propagate to `main` on the
  per-PBI merge. `commit-pbi.sh` excludes the symlink via
  `git add -A -- ':!.scrum'` and only it is safe.
- .scrum/pbi/<pbi-id>/ artifacts (design, reviews, metrics, feedback,
  summaries, pipeline.log, ut/ac-coverage-r{n}.json)
- backlog.json `items[].status` driven via
  `.scrum/scripts/update-backlog-status.sh` (Developer manages the
  `in_progress_*` range; SM owns the rest of the 12-value enum).
- Notification to SM via Agent Teams

## Status range owned by this skill (Developer side)

```
in_progress_design  → in_progress_impl ⇄ in_progress_pbi_review ⇄ in_progress_ut_run → in_progress_merge
                                                                                  → escalated  (any stage; via termination gate)
```

The 7 SM-managed status values (see [docs/data-model.md § State Transitions: status](../../docs/data-model.md#state-transitions-status-12-value-enum-actor-split)) MUST NOT be written by this skill.

## Stages (decision tree)

```text
[Init] create .scrum/pbi/<pbi-id>/ + state.json (rounds, *_status)
       update-backlog-status.sh "$PBI_ID" in_progress_design
   ↓
[Design Stage] Rounds 1..5 → see references/design-stage.md
   - status: in_progress_design
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
[Ready-to-merge handoff]
   - run .scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>
     (sets head_sha, paths_touched, ready_at; sets backlog status to
     in_progress_merge)
   - notify SM: "[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<id> sha=<head>"
   - stop and wait for SM SendMessage (MERGED / MERGE_CONFLICT /
     ARTIFACT_MISSING)
```

## Sub-agents spawned

See `references/sub-agent-prompts.md` for full input prompt templates.

- `pbi-designer` — Design Round Step 1 (sequential)
- `codex-design-reviewer` — Design Round Step 2 (sequential)
- `pbi-implementer` ‖ `pbi-ut-author` — Impl Round Step 1 (parallel pair)
- `codex-impl-reviewer` ‖ `codex-ut-reviewer` — PBI Review Stage (parallel pair)

All three `codex-*-reviewer` spawns share the stall fallback protocol
in `references/reviewer-stall-fallback.md` (2-min stall detect →
single Explore-agent retry → escalate as `reviewer_unavailable`).

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
