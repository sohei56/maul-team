# Product Brief Template

Fill-in skeleton for `docs/product/brief.md`. Target **1–2 pages**.
Write the Problem and Goals as **prose**; reserve bullets/tables for
scope, metrics, and priorities. Delete the parenthetical guidance
before saving. Sections marked *(optional)* may be omitted when the
project genuinely has nothing to put there — but an empty *Scope —
Out* or unmeasurable *Goals* is a defect, not an omission.

```markdown
# <Product / Project name> — Product Brief

## Problem & Context

(2–4 sentences of prose. What specific pain exists, for whom, and why
the status quo fails them. Lead with the pain, not a feature. If there
is evidence — a metric, a quote, an incident — name it.)

## Target Users

(The specific segment who has this problem and will use the solution.
Not "everyone". Name the role / situation and what they are trying to
get done.)

## Goals & Success Metrics

(The outcome that proves this worked, stated so it could be failed.
Each goal pairs an observable signal with a target. Outcomes, not
outputs — a change in the world, not "shipped feature X".)

- <Goal 1>: <falsifiable metric + target, e.g. "p95 dashboard load < 1s">
- <Goal 2>: <…>

## Scope — In

(What this project / first cycle delivers. Keep to the smallest set
that achieves the goals above.)

- <In-scope item>
- <…>

## Scope — Out / Non-Goals

(What is deliberately excluded. This is the YAGNI contract the team
enforces against — an autonomous team will gold-plate every plausible
adjacency that is not fenced off here. Be generous; list the tempting
things you are NOT doing.)

- <Out-of-scope / non-goal>
- <…>

## Constraints

(Hard limits the solution must respect. For an autonomous team, an
absent tech stack means a guessed — possibly wrong-but-irreversible —
architecture.)

- **Tech stack / platform**: <language, framework, runtime, target OS/browser>
- **Appetite / timeline**: <how much time/budget this is worth>
- **Data / regulatory**: <privacy, compliance, data residency, …>
- **Other**: <integrations, existing systems, team/skills limits>

## Priorities

(So there is a cut-line under the appetite. Mark must-have vs
nice-to-have.)

| Item | Priority (must / nice) |
|---|---|
| <…> | must |
| <…> | nice |

## Risks, Assumptions & Open Questions

(What could sink this; what is believed-but-unverified. Label each
assumption so the team validates rather than trusts it.)

- **Assumption**: <belief the plan depends on>
- **Risk**: <what could go wrong + rough severity>
- **Open question**: <unresolved decision the team must surface, not guess>

## Milestones (optional)

(Coarse phases, not a Gantt chart.)

- <Phase 1 — what "done" looks like>
- <Phase 2 — …>
```
