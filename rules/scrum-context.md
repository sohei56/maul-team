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

You are running inside the **Maul Team** framework. Multiple
Claude sessions cooperate as a Scrum team. This file gives you the
shared mental model every agent needs **before acting**.

This file is **behavior guidance**, not a spec re-statement.
For specs, follow the pointers in [Where to look](#where-to-look-for-what).

## Your team and your seat

```
        PO seat (one of two — see § PO seat resolution):
        ┌─────────────────────────────────────────────────────────┐
        │ po_mode=human   →  USER (the human, via main session)   │
        │ po_mode=agent   →  product-owner teammate (Agent Teams, │
        │                    spawned and re-spawned by SM)        │
        └─────────────────────────────────────────────────────────┘
                          │
                          ▼
                   Scrum Master  (team lead, Delegate mode — never writes code)
                          │
              (project start) spawn requirements-analyst  ──▶  Requirement
                          │      Definition ceremony: interview + mandatory
                          │      benchmark web search + requirements.md
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
                          │
     Integrity stage (Round tail, before ready-to-merge — the
     5 aspect reviewers now run PER-PBI here, not Sprint-end):
       requirement-conformance / functional-quality / security
       / maintainability / docs-consistency  reviewers

   Sprint-end (SM-owned, AUDIT-ONLY, non-blocking, parallel via Agent tool):
     codebase-audit 4 axes: spec-conformance / logic-defect
     / redundancy / product-security
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
| All PBIs, statuses (13-value enum) | `.scrum/backlog.json` |
| Your PBI's internal pipeline state, round counters, merge fields, paths_touched | `.scrum/pbi/<pbi-id>/state.json` |
| PBI lifecycle graph, status semantics | `../docs/data-model.md` |
| Inter-agent message contracts, envelope schema | `../docs/contracts/agent-interfaces.md`, `../docs/contracts/sub-agents.md` |
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
   prior verdicts, escalation_reason). A status of `escalated`,
   `blocked`, or `cancelled` means do not proceed — surface it to
   your caller.
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
- **PBI pipeline sub-agents** (designer / implementer / ut-author /
  codex reviewers) **end output with the JSON envelope** specified by
  `docs/contracts/pbi-pipeline-envelope.schema.json`. Missing or
  malformed envelopes break the pipeline orchestrator's parser.
  Integrity aspect reviewers are the exception — they return the
  markdown `**Verdict: PASS|FAIL**` per their agent definitions.

**PO-channel prefixes** (SM ↔ product-owner teammate when
`po_mode=agent`). All are prefixed `[<scope>]` where `<scope>` ∈
`{pbi-NNN, sprint-N, product}`. Full syntax, the `kind` enum, and the
clarification cap are **canonical in `../agents/product-owner.md`
§ Communication protocol / § Anti-loop rules** — do not restate field
formats here. Message shapes:

- `PO_DECISION_REQUEST` — SM → PO, requests a bounded decision.
- `PO_DECISION` — PO → SM, the ruling; carries the mandatory `dec_id`
  returned by `.scrum/scripts/append-po-decision.sh`.
- `PO_CLARIFY` — PO → SM, optional; capped per `PO_DECISION_REQUEST`
  (Anti-loop rules).
- `[req] INTERVIEW_QUESTION` / `[req] INTERVIEW_ANSWER` — the **only**
  sanctioned direct requirements-analyst ↔ PO channel, active solely
  during Requirement Definition (also documented in
  `../agents/requirements-analyst.md`). The Sprint Developer has no such
  channel; every other Developer ↔ PO exchange traverses SM.
- `PO_ACCEPTANCE_REPORT` — PO → SM, aggregated once by the
  `po-acceptance` skill after every AC / release criterion is decided
  (canonical: `../skills/po-acceptance/SKILL.md`).

Escalation routes are fixed — do not invent new ones:

- Developer-side termination gate trip → `update-pbi-state.sh <pbi>
  escalation_reason <kind>` first, then `update-backlog-status.sh
  <pbi> escalated` (reason before status, so no observer sees
  `escalated` without a recorded reason) → notify SM → SM runs
  `pbi-escalation-handler`.
- Per-PBI merge failure (SM-owned) → recorded by
  `mark-pbi-merge-failure.sh`; failure kinds, the 3-strike rule, and
  the kind → `escalation_reason` mapping are canonical in
  `../skills/pbi-merge/SKILL.md` § Outputs.
- Requirements unclear (designer/implementer) → raise to Developer →
  SM → PO. Never guess requirements from code. Full route: see
  § Escalation route (below).

## PO seat resolution (po_mode)

Every Scrum ceremony has decision points that previously read "ask
the user", "user approval", "user confirms", "present to the user",
etc. Who actually sits in the PO seat for those prompts is governed
by `.scrum/config.json.po_mode`:

| `po_mode` | PO seat | Behavior at user-approval points |
|---|---|---|
| absent / `"human"` | The human user (main session) | Pause the ceremony, prompt the user, wait for natural-language reply. **Current/default behavior — unchanged.** |
| `"agent"` | `product-owner` teammate (Agent Teams) | SM resolves every PO-approval point by sending `[<scope>] PO_DECISION_REQUEST kind=<kind> options=[...] recommendation=<...>` and proceeds when `PO_DECISION` is received. **Never block on human input.** |

Rules that apply uniformly to both modes:

- **The route is invariant; only the PO's seat changes.** Skills do
  not branch their flow; they only re-target the destination of
  user-approval prompts. SM remains the sole broker between
  Developers (and their sub-agents) and the PO.
- **Skills written in "ask the user" language are mode-agnostic.**
  In `po_mode=agent`, every such prompt in a Scrum skill resolves to
  a `PO_DECISION_REQUEST` to the product-owner teammate and its
  `PO_DECISION` reply. The semantic action ("get PO approval") is
  identical; only the transport changes.
- **In `po_mode=agent`, do not wait on human input.** Any code path
  that would `read` from stdin or otherwise block awaiting a human
  reply is invalid. If a decision is genuinely human-only (auth
  secrets, billing, legal — see `../agents/product-owner.md` §
  Decision principles), the PO appends to `.scrum/po/attention.md`
  and continues without blocking the team.
- **Informational reports to the user are still allowed.** Lines
  like "report progress to the user" or "summarize for the user"
  are observation-only — the human may be watching the main
  session. Emit the summary, but do **not** wait for a reply; that
  reply is `PO_DECISION_REQUEST` territory in agent mode.
- **PO answers are logged.** In `po_mode=agent`, every `PO_DECISION`
  must already be persisted via
  `.scrum/scripts/append-po-decision.sh` (which returns the
  `dec_id`); the SM uses `dec_id` to back-link the decision.
  Decision-log writes are part of the protocol, not optional.

Canonical sources: the `po_mode` schema is in
`docs/contracts/scrum-state/config.schema.json`; the PO message
shapes and `kind` enum are normative in
`../agents/product-owner.md` § Communication protocol; the wrapper
contract is in `scripts/scrum/append-po-decision.sh` (deployed as
`.scrum/scripts/append-po-decision.sh`).

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
        │  po_mode=human → consults the user via main session (current)
        │  po_mode=agent → SendMessage to product-owner teammate:
        │    [<pbi-id>] PO_DECISION_REQUEST kind=spec_clarification q=<...>
        ▼
   PO answers (logged to .scrum/po/decisions.json via
   append-po-decision.sh in agent mode) → SM relays back → Developer
   relays to sub-agent → sub-agent resumes the current Round
```

Only the PO seat changes between modes; the route shape itself is
invariant. "Escalation routes are fixed" still holds — SM remains the
single broker, and sub-agents never address the PO directly (the one
exception is the requirement-definition `[req] INTERVIEW_*` channel
owned by the `requirements-analyst`; see § Communication protocol).

This is a synchronous path: the spawning sub-agent should end its
turn with the question in `findings[]` and a `next_actions` entry
naming the unresolved spec point, rather than emitting a guessed
artifact. The Round is not "complete" until the question is
answered or the PBI is reassigned.

In reports, **separate fact from interpretation**: "tests fail with
`AssertionError at line 42`" is a fact; "the impl is probably wrong"
is interpretation. Both are useful — labeled differently.

### Agent tool unavailability (harness incident — DO NOT invent workaround)

If a Developer reports `Agent` / `Task` tool is not in the deferred-tool
list, or any sub-agent spawn raises a harness-level failure (not a PBI
content issue), this is a **harness incident**, not a PBI termination
condition.

**The following terms are NOT defined anywhere in `../skills/pbi-pipeline/`
or any other skill. Do not write them to `pipeline.log`, `state.json`,
or any review file. They are not valid states:**

- `SM override`
- `self_authored`
- `self_reviewed`
- `conductor-driven`
- `agent_tool_unavailable` as an `escalation_reason` (the enum does
  not contain this value)

**Correct response (SM-side):**

- `po_mode=human` → halt the Sprint and surface the harness incident to
  the user via the main session. Do NOT proceed with PBI work in any
  form until the user resolves whether to (a) restart the session with
  Agent tool exposed, or (b) explicitly amend the spec.
- `po_mode=agent` → write the incident to `.scrum/po/attention.md` with
  full transcript pointer, set Sprint status appropriately, and stop.
  The watchdog will surface this on the next morning report.

**"per pbi-XXX precedent" is never valid justification.** Agents do not
create case law. If a prior PBI completed via an undefined path, that
PBI was bugged, not blessed — surface it for review, do not extend it.

The Developer who reports this is doing the **right thing**, even if it
blocks the Sprint. Reward the report; never instruct the Developer to
"just write the code inline" as a workaround.

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
- **PBI lifecycle, status enum, transitions** → `../docs/data-model.md`
- **Inter-agent contracts, envelope schemas** → `../docs/contracts/agent-interfaces.md`
- **Code style, git workflow, state-write rules** → `CLAUDE.md`
- **Why a wrapper script behaves a given way** → `.scrum/scripts/<name>.sh` source and the schema files under `docs/contracts/scrum-state/`
