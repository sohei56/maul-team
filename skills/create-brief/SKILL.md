---
name: create-brief
description: >
  Co-author a product brief (docs/product/brief.md) with the human
  through a structured interview, then quality-gate it against
  best practices. The brief is the single human-authored input that
  anchors every scope / YAGNI decision the team makes — in both human
  and autonomous modes. It anchors the Requirement Definition interview
  (the Requirements Analyst reads it first and reconciles requirements
  against it) and, in autonomous mode, is the Product Owner's source of
  truth. Use when no brief exists yet, when a brief is thin or
  unmeasurable, or when the operator runs `/create-brief`.
disable-model-invocation: false
---

## What a product brief is (read first)

A **product brief** is a short (1–2 page) human-authored narrative
that anchors a project by stating, *before* committing to a
solution: the **problem**, the **people who have it**, the
**outcome that counts as success**, and the **boundaries of
scope**. It is a decision-anchoring orientation doc and a scope
contract — **not** a PRD (detailed requirements/user stories),
**not** a vision doc (multi-year aspiration, no boundaries), and
**not** an engineering spec (interfaces, schemas, sequencing).

It anchors work in **both modes**. In human mode the Requirements
Analyst reads it first and drives the Requirement Definition interview
from it, reconciling any requirement that conflicts with the brief. In
autonomous mode the Product Owner expands this brief into
`docs/product/vision.md` and then answers every "is this in scope?"
question against it. **Anything left implicit in the brief becomes an
unbounded guess for an autonomous team that cannot ask hallway
follow-ups.** The brief must be *self-sufficient*: every scope / YAGNI
decision the team will face should be resolvable from the problem, the
falsifiable metrics, the explicit non-goals, the stated constraints,
and the priorities.

Deeper rationale, sources, and the section-by-section quality bar
live in [references/brief-best-practices.md](references/brief-best-practices.md).
The fill-in skeleton lives in [references/brief-template.md](references/brief-template.md).

## Inputs

- Operator/user dialogue (the human is the source of truth)
- Existing `docs/product/brief.md` if present (refine, don't clobber)
- `references/brief-template.md`, `references/brief-best-practices.md`

## Outputs

- `docs/product/brief.md` — 1–2 page brief following the template
- A short verbal summary of unresolved assumptions / open questions

## Preconditions

- A human is present (this is an interactive ceremony; it cannot run
  headless). On a **new project in either mode**, `scrum-start.sh`
  invokes this skill as a **pre-flight interactive step** (before the
  Scrum Master's Requirement Definition in human mode, or before the
  watchdog in autonomous mode) whenever `docs/product/brief.md` is
  absent and stdin is a TTY. Human mode with no TTY skips the pre-flight
  and proceeds; autonomous mode with no TTY errors out (a brief cannot
  be co-authored without a human, and the autonomous PO cannot run
  without one).
- `docs/product/` is writable (create it if missing).

## Mindset (hold these while interviewing)

1. **Problem before solution.** Earn the right to propose a solution
   by nailing the problem first. If the user opens with a feature
   ("build me an X"), ask *what pain X removes and for whom* before
   recording anything.
2. **Outcomes over outputs.** Success is a change in the world, not a
   shipped artifact. Push "ship feature Y" → "what becomes true once
   Y ships, and how would we measure it?"
3. **Ruthless scoping / YAGNI.** A fixed appetite (time/budget) is a
   forcing function. Drive toward the smallest thing that delivers the
   outcome. Every "wouldn't it be nice…" is a candidate for *Out*.
4. **Make non-goals explicit.** The unsaid "out" is where scope leaks.
   A brief with no out-of-scope list is incomplete.
5. **Falsifiable success criteria.** A metric you could *fail* is a
   real metric. "Improve engagement" is a wish; "p95 page load < 1s on
   the dashboard route" is testable.
6. **Narrative beats bullet soup.** Prose exposes fuzzy thinking that
   bullets hide. Write the problem and goals as sentences; reserve
   bullets/tables for scope lists and metrics.

Stay in metacognition-coach posture: when an answer is vague,
solutioning-too-early, or unmeasurable, **name it and ask a sharper
question** rather than recording it as-is. Separate fact ("the user
said X") from your inference.

## Steps

1. **Locate context.** Read `docs/product/brief.md` if it exists.
   - Absent → you are co-authoring from scratch (the common
     autonomous-launch case).
   - Present but thin/unmeasurable → offer to **refine in place**;
     do not silently overwrite. Show the user what is weak (per the
     quality bar) and ask which sections to strengthen.
   - Present and already strong → say so, ask if anything changed,
     and stop rather than busy-work.

2. **Set expectations (one short message).** Tell the user: this is a
   ~1–2 page brief, you will ask one topic at a time (≈8 topics),
   answers can be rough — you will draft prose from them — and the
   goal is a brief an autonomous team can act on without follow-ups.

3. **Interview, one topic at a time.** Walk the sections below in
   order. After each answer, if it is vague / solutioning / a feature
   list / "everyone" / unmeasurable, ask **one** sharpening follow-up
   before moving on. Do not dump all questions at once.

   1. **Problem & context** — what pain, for whom, why the status quo
      fails. (Reject "we need feature X"; get the underlying pain.)
   2. **Target users** — the specific segment. (Reject "everyone".)
   3. **Goals & success metrics** — the falsifiable outcome(s) with a
      target. (Reject unmeasurable or output-shaped goals.)
   4. **Scope — In** — what this project/first cycle delivers.
   5. **Scope — Out / Non-goals** — what is deliberately excluded.
      (If the user has none, probe: every plausible adjacency an
      autonomous team might gold-plate belongs here.)
   6. **Constraints** — tech stack, platform, budget/appetite,
      timeline, regulatory/data limits. (Critical for autonomous:
      absent stack → the team guesses an architecture.)
   7. **Priorities** — must-have vs nice-to-have, so there is a
      cut-line under the appetite.
   8. **Risks, assumptions & open questions** — what could sink it;
      label each unverified belief as an assumption, not a fact.
   9. **Milestones (optional, coarse)** — phases, not a Gantt chart.

4. **Draft `docs/product/brief.md`.** Use the template structure.
   Write the problem and goals as **prose**; use bullets/tables only
   for scope lists, metrics, and priorities. Keep it to 1–2 pages —
   push detail to future PRDs/specs, not into the brief.

5. **Quality-gate the draft (do not skip).** Check against the smell
   list — flag and fix any that are present:
   - success metric vague or absent / not falsifiable
   - no "Scope — Out" / no non-goals
   - solutioning (UI, schema, framework) where the problem belongs
   - scope unbounded (no appetite/budget/timeline)
   - target users = "everyone"
   - goals phrased as features-to-ship
   - assumptions stated as facts
   - the doc has grown toward a spec (too long)
   Show the user the flagged items and resolve them with one more
   round of questions. State plainly when a gap remains unresolved
   (record it under *Open questions*) rather than papering over it.

6. **Write the file and confirm.** Save `docs/product/brief.md`.
   Summarize in 2–3 lines: the problem, the headline success metric,
   and any open questions the team will have to validate.

7. **Hand off.**
   - If this was invoked at **autonomous launch** (pre-flight): tell
     the user the brief is complete and that **autonomous mode will
     start when they exit this session** (`scrum-start.sh` chains the
     watchdog after this session ends).
   - If invoked **standalone** (`/create-brief`): tell the user the
     brief is ready and how to use it — e.g. start autonomous mode
     with `scrum-start.sh --autonomous` (the brief is now at the
     canonical path), or hand it to the Requirement Definition.

## Anti-patterns (do not do these)

- **Do not invent answers.** If the user does not know a constraint or
  metric, record it as an open question — never fabricate a target,
  stack, or scope boundary to make the brief look complete.
- **Do not let it grow into a PRD.** When the user starts dictating
  detailed requirements or interface contracts, note them for a later
  PRD/design doc and steer back to brief altitude.
- **Do not run without a human.** This skill requires interactive
  dialogue. If there is no human to answer, stop and surface that —
  do not author a brief from assumptions.
- **Do not overwrite a strong existing brief** to "regenerate" it.
  Refine in place.
