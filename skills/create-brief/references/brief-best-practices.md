# Product Brief — Best-Practices Reference

Synthesis of web best practices for writing a product brief, adapted
for a brief that an **autonomous AI software-development team** will
consume as its single source of truth. Read this when you need the
"why" behind a section or the quality bar for judging a draft.

## 1. What a brief is (and is not)

A product brief is a short (1–3 page, ideally 1–2) human-authored
**narrative** that anchors a project by stating the **problem**, the
**people who have it**, the **outcome that counts as success**, and
the **boundaries of scope** — *before* committing to a solution. It is
a decision-anchoring orientation doc and a scope contract.

| It IS | It is NOT |
|---|---|
| Problem + outcome + guardrails, at a high altitude | A PRD (detailed requirements, user stories, acceptance specs) |
| A scope contract the team enforces YAGNI against | A vision doc (multi-year, aspirational, no boundaries) |
| Short enough to read in one sitting | An engineering spec (interfaces, schemas, sequencing) |

Cagan/SVPG frame the core shift: traditional teams are handed a
*feature list to build*; empowered product teams are handed a
*problem to solve and an outcome to achieve*. The brief lives at that
"problem + outcome + guardrails" altitude — not the feature-list
altitude below it, nor the vision altitude above it.

Amazon's PR/FAQ ("Working Backwards") is a parallel form: a
future-dated press release plus an internal/external FAQ that forces
customer-first clarity and exposes fuzzy thinking before any code is
written.

## 2. Canonical sections

Converging across Asana, Basecamp's Shape Up, Lean Canvas, and
Lenny's 1-pager, a strong brief contains:

| Section | What goes in | Common failure mode |
|---|---|---|
| **Problem / context** | The specific pain, with a concrete story of why the status quo fails | Stated as a missing feature ("we need X") instead of a user pain |
| **Target users** | Who has the problem and why they'll use the thing | "Everyone" / no real segment |
| **Goals & success metrics** | The measurable outcome that proves it worked | Vague ("improve engagement") or output-shaped ("ship feature") |
| **Scope — In** | What's included this cycle | Listed without a matching "Out" |
| **Scope — Out / Non-goals** | What is deliberately *not* pursued | Absent → scope creeps toward the "perfect" solution |
| **Constraints / appetite** | Time, budget, tech stack, platform, regulatory limits | Unbounded → every "what about…" expands the work |
| **Priorities** | Must-have vs nice-to-have | Flat list → no basis for a cut-line under the budget |
| **Risks, assumptions, open questions** | What could sink it; what's unverified | Assumptions stated as facts; surface mid-build |
| **Milestones** | Coarse phases | Over-detailed schedule masquerading as a plan |

Shape Up contributes three sharp ideas worth borrowing:
- **Appetite** — a *budget* that shapes the solution ("how much time is
  this worth?"), not an estimate of a predetermined solution.
- **No-gos** — explicit out-of-bounds items.
- **Rabbit holes** — known places where hidden complexity lurks; call
  them out so they don't ambush the build.

## 3. Writer's mindset / principles

1. **Problem before solution.** Separate the problem from any
   solution; earn the right to propose one.
2. **Outcomes over outputs.** Define success as a change in the world,
   not a shipped artifact.
3. **Ruthless scoping / YAGNI.** Fixed appetite is a forcing function;
   cut the solution to fit the time, don't expand time to fit ideas.
4. **Make non-goals explicit.** Fences are as load-bearing as goals;
   the unsaid "out" is where scope leaks.
5. **Falsifiable success criteria.** A metric you could fail is a real
   metric; an unmeasurable goal is a wish.
6. **Written narrative beats bullet soup.** Prose exposes fuzzy
   thinking that bullets hide (Amazon mandates prose for this reason).
7. **Customer language, no jargon.** Write so the user — and any later
   reader, human or agent — understands it immediately.
8. **Brevity as discipline.** A length limit is a forcing function;
   long docs hide weak ideas.

## 4. Quality bar / smells

**A good brief:** one concrete problem with evidence; a named user
segment; at least one falsifiable metric with a target; an explicit
out-of-scope / non-goals list; stated constraints and assumptions;
reads as scannable prose in a single sitting.

**Red flags:**
- success metric is vague or absent
- no "what we're NOT doing"
- solutioning (UI, schema, tech choices) before the problem is
  established
- scope is unbounded (no appetite/budget/timeline)
- "target users = everyone"
- goals phrased as features-to-ship
- assumptions stated as facts
- the doc keeps growing toward a spec

## 5. Length / format

**1–2 pages.** Asana recommends keeping a brief under ~3 pages so it
stays user-friendly and pushing detail to supporting docs. Amazon caps
PR/FAQ length deliberately as a forcing function. Short because the
brief's job is *alignment and scope-anchoring*, not exhaustive
specification — and because the constraint itself sharpens thinking.
Favor prose for reasoning, with bullets/tables only for scope lists,
metrics, and priorities.

## 6. Anti-patterns for an autonomous AI consumer

An autonomous team can't ask casual hallway follow-ups, so brief
defects become silent wrong-but-confident output. Guard against:

- **Ambiguity / no acceptance criteria.** If success isn't measurable
  and testable, the team can't self-verify "done". Each goal needs an
  observable, checkable outcome.
- **Missing out-of-scope / non-goals.** Without explicit fences, an
  agent over-builds (gold-plates) every plausible adjacency. Non-goals
  are the YAGNI contract the team enforces against.
- **No constraints / tech stack.** Absent language, framework,
  platform, or data constraints, the agent guesses an architecture
  that may be wrong-but-irreversible. State the stack and hard limits.
- **No priorities.** A flat feature list gives no basis for cut-line
  decisions under a budget; rank or mark must-have vs nice-to-have.
- **Solutioning too early / under-specified contracts.** Half-specified
  interfaces invite the agent to invent signatures and business rules —
  exactly the "guess vs escalate" hazard. Either pin the contract or
  mark it explicitly open.
- **Assumptions unmarked.** Label each as assumption / open question so
  the team knows what to validate rather than treat as ground truth.

**Net:** for an autonomous consumer, the brief must be
*self-sufficient* — every scope / YAGNI decision the team will face
should be resolvable from the problem, the falsifiable metrics, the
explicit non-goals, the stated constraints, and the priorities.
Anything left implicit becomes an unbounded guess.

## Sources

- SVPG / Marty Cagan — Product Operating Model:
  <https://www.svpg.com/the-product-operating-model-an-introduction/>
- Amazon "Working Backwards" PR/FAQ:
  <https://workingbackwards.com/concepts/working-backwards-pr-faq-process/>
- Basecamp, Shape Up — "Write the Pitch" (Ch.6):
  <https://basecamp.com/shapeup/1.5-chapter-06>
- Asana — Product Brief / Project Brief templates:
  <https://asana.com/resources/product-brief-template> ·
  <https://asana.com/resources/project-brief>
- Atlassian — Product Requirements (PRD):
  <https://www.atlassian.com/agile/product-management/requirements>
- Lenny's Newsletter — PRDs & 1-pagers, with examples:
  <https://www.lennysnewsletter.com/p/prds-1-pagers-examples>
- Ash Maurya — Lean Canvas:
  <https://www.leanstack.com/lean-canvas>
