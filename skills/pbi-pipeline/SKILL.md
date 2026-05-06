---
name: pbi-pipeline
description: >
  PBI development pipeline — orchestrates design phase and impl+UT
  phase with sub-agent fan-out, file-based handoff, deterministic
  termination gates (Anthropic + Ralph + GAN-derived). Used by
  Developer per assigned PBI. Replaces former design + implementation
  skills.
disable-model-invocation: false
---

## Inputs

- PBI assignment (backlog.json entry for assigned PBI)
- requirements.md path
- Related catalog specs (read-only references)
- .scrum/config.json
- 6 sub-agent definitions verified by install-subagents

## Outputs

- Source code + test code committed to the PBI branch in the PBI
  worktree via `.scrum/scripts/commit-pbi.sh`. Never commit
  directly with raw `git commit`.
- .scrum/pbi/<pbi-id>/ artifacts (design, reviews, metrics, feedback,
  summaries, pipeline.log)
- backlog.json status: auto-derived from `pbi/<id>/state.json.phase` by
  `update-pbi-state.sh` (in_progress while design/impl_ut, review at
  complete, done at review_complete, blocked at escalated).
  **Never write `backlog.json.status` directly from this skill.**
- Notification to SM via Agent Teams

## Phases (decision tree)

```text
[Init] create .scrum/pbi/<pbi-id>/ + state.json
   ↓
[Design Phase] Rounds 1..5 → see references/phase1-design.md
   ↓ success
[Impl+UT Phase] Rounds 1..5 → see references/phase2-impl-ut.md
   - per round: spawn impl + UT in parallel
   - measure coverage → see references/coverage-gate.md
   - spawn impl-reviewer + UT-reviewer in parallel
   - aggregate + judge + (FAIL only) build feedback
     → see references/feedback-routing.md
   - termination check → see references/termination-gates.md
   ↓ success
[Completion]
   - run .scrum/scripts/mark-pbi-ready-to-merge.sh <pbi-id>
     (sets phase=ready_to_merge, head_sha, paths_touched, ready_at;
     projects backlog status to review)
   - notify SM: "[<pbi-id>] PBI_READY_TO_MERGE branch=pbi/<id> sha=<head>"
   - stop and wait for SM SendMessage (MERGED / MERGE_CONFLICT /
     ARTIFACT_MISSING / MERGE_REGRESSION)
```

## Sub-agents spawned

See `references/sub-agent-prompts.md` for full input prompt templates.

| Agent | When | Parallel with |
|---|---|---|
| pbi-designer | Design Round Step 1 | – |
| codex-design-reviewer | Design Round Step 2 | – |
| pbi-implementer | Impl+UT Round Step 1 | pbi-ut-author |
| pbi-ut-author | Impl+UT Round Step 1 | pbi-implementer |
| codex-impl-reviewer | Impl+UT Round Step 3 | codex-ut-reviewer |
| codex-ut-reviewer | Impl+UT Round Step 3 | codex-impl-reviewer |

## State management

PBI internal state: `.scrum/pbi/<pbi-id>/state.json`. See
`references/state-management.md` for schema, write helpers, and
pipeline.log format.

## Parallel PBI coordination

Catalog write contention: see `references/catalog-contention.md`
(3-layer defense: sprint planning pre-separation + flock + mtime check).

## Escalation

When termination gate triggers escalation, set `state.phase=escalated`,
write escalation_reason, notify SM via Agent Teams. SM handles via the
`pbi-escalation-handler` skill.

## Exit Criteria

- state.json: `phase = ready_to_merge` OR `phase = escalated`
- backlog.json items[].status reflects the projected value (`review`
  for both ready_to_merge and merged; `blocked` for escalated). The
  pipeline does not write it directly.
- SM notified
