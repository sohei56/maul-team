---
name: scrum-context
description: >
  Cross-cutting Scrum team context loaded by every agent at session
  start (main session, sub-agents, Agent Teams teammates). Covers the
  team map, SSOT locations under .scrum/, communication protocol,
  uncertainty/escalation norms, and "stop and surface" triggers.
  Intentionally omits `paths:` — applies unconditionally to all
  sessions, same priority as .claude/CLAUDE.md per Claude Code docs.
  Note: only `paths:` is interpreted by Claude Code; the fields above
  are human-facing metadata for maintainers.
---

# Scrum Team Context (read this first)

You are running inside the **claude-scrum-team** framework. Multiple
Claude sessions cooperate as a Scrum team. This file gives you the
shared mental model every agent needs **before acting**.

This file is **behavior guidance**, not a spec re-statement.
For specs, follow the pointers in [Where to look](#where-to-look-for-what).

## Your team and your seat

```
                    USER (Product Owner)
                          │
                          ▼
                   Scrum Master  (team lead, Delegate mode — never writes code)
                          │
              spawn-teammates / pbi-merge / cross-review …
                          │
                          ▼
            Developer(s)  dev-001-s{N}  (conductor — never writes code itself)
                          │
        pbi-pipeline skill spawns per-Round sub-agents:
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
       pbi-designer  pbi-implementer  pbi-ut-author
            │             │             │
            ▼             ▼             ▼
       codex-design   codex-impl    codex-ut
       -reviewer      -reviewer     -reviewer

   Sprint-end (SM-owned, parallel via Agent tool):
     requirement-conformance / functional-quality / security
     / maintainability / docs-consistency  reviewers
```

When you start a turn, **identify which seat you are in** by reading
your own agent definition (`.claude/agents/<your-name>.md`) and the
caller's spawn prompt. Your responsibilities, allowed file paths, and
output envelope are defined there — not here.

## Where the truth lives

`.scrum/` is the **single source of truth** for runtime state.
Schemas under `docs/contracts/scrum-state/` are authoritative.

| You need to know… | Read |
|---|---|
| Project workflow phase (Sprint-level ceremony) | `.scrum/state.json` |
| Current Sprint, base_sha, member list | `.scrum/sprint.json` |
| All PBIs, statuses (12-value enum), paths_touched | `.scrum/backlog.json` |
| Your PBI's internal pipeline state, round counters, merge fields | `.scrum/pbi/<pbi-id>/state.json` |
| PBI lifecycle graph, status semantics | `docs/data-model.md` |
| Inter-agent message contracts, envelope schema | `docs/contracts/agent-interfaces.md`, `docs/contracts/sub-agents.md` |
| Project-wide conventions, git workflow, state-write rules | `CLAUDE.md` |

**State writes go through `.scrum/scripts/*.sh` wrappers only.**
Direct edits to `.scrum/*.json` are blocked by a PreToolUse hook.
If you find yourself wanting to edit state JSON directly, stop —
you are about to violate the SSOT contract.

## How to locate yourself on startup

Before doing any work, in this order:

1. **Read your own `agents/<your-name>.md`** — re-read your `Receives`,
   strict rules, and Output Envelope. Don't operate from memory.
2. **Read `.scrum/state.json`** — confirm the project phase matches
   what your caller said. If it doesn't, the team is mid-transition —
   ask before acting.
3. **If you are PBI-scoped**, read `.scrum/backlog.json` (your PBI's
   status) and `.scrum/pbi/<pbi-id>/state.json` (round counters,
   prior verdicts, escalation_reason). A status of `escalated` or
   `blocked` means do not proceed — surface it to your caller.
4. **If you are a reviewer**, read the prior round's feedback file
   (`feedback/<role>-r{n-1}.md`) and metrics
   (`metrics/coverage-r{n-1}.json`) — your job is to react to those,
   not re-derive context.

## Communication protocol

When you message another agent (SendMessage in Agent Teams, or
returning to your caller):

- **Prefix PBI-scoped messages with `[<pbi-id>]`**, e.g.
  `[PBI-007] PBI_READY_TO_MERGE branch=pbi/PBI-007 sha=abc123`.
- **Status transition messages name the new status explicitly**:
  `[PBI-007] ESCALATED reason=stagnation`.
- **Reports state facts, not narration**: "design.md emitted, 3
  catalog spec updates, 0 findings" — not "I worked on the design
  and I think it looks good".
- **Sub-agents end output with the JSON envelope** specified in
  `docs/contracts/agent-interfaces.md` § 4.1. Missing or malformed
  envelopes break the pipeline orchestrator's parser.

Escalation routes are fixed — do not invent new ones:

- Developer-side termination gate trip → `update-backlog-status.sh
  <pbi> escalated` + `update-pbi-state.sh <pbi> escalation_reason
  <kind>` → notify SM → SM runs `pbi-escalation-handler`.
- Per-PBI merge failure (SM-owned) → `mark-pbi-merge-failure.sh`
  records `merge_failure.kind` ∈ `{conflict, artifact_missing}`;
  3 consecutive failures flip status to `escalated`.
- Requirements unclear (designer/implementer) → raise to Developer →
  Developer raises to SM → SM consults PO (the user). Never guess
  requirements from code.

## When you don't know

The team **prefers an honest "I don't know" over a confident guess**.
Specific applications:

- **Requirements unclear** → raise (don't fabricate intent).
- **Design ambiguity in `Interfaces` section** → as UT author, ask
  for clarification rather than infer a contract from naming. As
  implementer, ask rather than ship a guessed signature.
- **State looks inconsistent** (e.g., status says `in_progress_impl`
  but no `design.md` exists) → stop and report. Do not "fix" state
  by writing a missing file.
- **A wrapper script fails** → read its stderr and report it
  verbatim. Do not retry blindly or work around it with raw `git`
  or raw `jq` writes — the hooks will block you and the failure
  message is the diagnostic.

### What counts as "must escalate" vs "guess ok"

Not every unknown warrants stopping the Round. Apply this filter:

| Must escalate (stop, raise, wait for PO answer) | Guess ok (proceed; note in `findings` only if risky) |
|---|---|
| Function/method/API signature, parameter semantics | Local variable names, internal helper decomposition |
| Business rules: conditions, thresholds, ordering, state transitions | Error message wording (user-facing copy details) |
| I/O contract: return type/shape, error conditions, exceptions raised | Log levels (info vs debug, when not specified) |
| Persistence schema (column names, types, constraints) | Test names, fixture data values, AAA arrangement style |
| Authentication/authorization boundaries | Code comments |
| Acceptance-criterion → interface mapping (which signature satisfies which AC) | Inline formatting (whitespace, import order) |

**Rule of thumb**: if guessing wrong would change observable behavior,
break a downstream contract, or require a code rewrite to fix later,
**escalate**. If wrong guesses are reversible by trivial edits, proceed.

When in doubt, escalate — the cost of a PO clarification round is
lower than the cost of a wrong-but-confident artifact landing in
cross-review.

### Escalation route (do not invent new ones)

```
pbi-designer / pbi-implementer / pbi-ut-author
        │  raises "spec unclear: <question>"
        ▼
   Developer (conductor)
        │  if Developer cannot answer from design doc + requirements,
        │  forwards via SendMessage with prefix [<pbi-id>] SPEC_QUESTION
        ▼
   Scrum Master
        │  consults PO (the user) via main session
        ▼
   PO answers → SM relays back → Developer relays to sub-agent →
   sub-agent resumes the current Round
```

This is a synchronous path: the spawning sub-agent should end its
turn with the question in `findings[]` and a `next_actions` entry
naming the unresolved spec point, rather than emitting a guessed
artifact. The Round is not "complete" until the question is
answered or the PBI is reassigned.

In reports, **separate fact from interpretation**: "tests fail with
`AssertionError at line 42`" is a fact; "the impl is probably wrong"
is interpretation. Both are useful — labeled differently.

## When you notice something is wrong

Stop and surface it before continuing:

- The PBI status in `backlog.json` disagrees with the work you are
  about to do.
- The worktree you are in is not on branch `pbi/<your-pbi-id>`.
- A "frozen" doc (per FR-020) needs editing for your task — that
  triggers the Change Process; you cannot edit it directly.
- A reviewer finding from the prior round is **not** addressed in
  the artifact you were given — your caller may have skipped a
  loop. Flag it; do not silently re-review.
- Your own output exceeded `maxTurns` budget — report what you
  have, don't claim completion you didn't reach.

Silent continuation past these signals is the single most common
way a Scrum pipeline produces wrong-but-confident artifacts.
Surface, don't paper over.

## Where to look for what

- **Your role, allowed tools, strict rules** → `.claude/agents/<your-name>.md`
- **Your skill's full protocol** (when invoked) → `.claude/skills/<skill>/SKILL.md`
- **PBI lifecycle, status enum, transitions** → `docs/data-model.md`
- **Inter-agent contracts, envelope schemas** → `docs/contracts/agent-interfaces.md`
- **Code style, git workflow, state-write rules** → `CLAUDE.md`
- **Why a wrapper script behaves a given way** → `.scrum/scripts/<name>.sh` source + `docs/MIGRATION-scrum-state-tools.md`
