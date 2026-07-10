# Deploy-sync + upstream feedback loop (DEFERRED)

**Status: deferred by operator decision (2026-07-10).** Do not
implement without revisiting the privacy constraint below.

## Problem

The framework source (this repo) and its deployed copies in target
projects (`.scrum/scripts/`, `.claude/agents|skills|rules/`) drift in
BOTH directions, and each direction has produced real damage:

- **Downstream-stale**: fixes land in this repo but never reach a
  target's deployed copies, so target-project retrospectives keep
  reporting bugs that are already fixed at HEAD — several recurred
  for multiple Sprints for exactly this reason.
- **Upstream-lost**: mid-Sprint hotfixes are applied to the deployed
  (gitignored) runtime copy only and never upstreamed to this repo,
  so the next re-deploy silently reverts them and the same failure
  re-hits. A target-project retrospective identified this mechanism
  explicitly.

## Sketch (unvalidated)

1. **Version stamp**: `setup-user.sh` records the framework commit
   sha into the deployed tree (e.g. `.scrum/scripts/.deployed-sha`);
   `setup-user.sh --check` diffs deployed files against that sha and
   reports drift in both directions.
2. **Redeploy discipline**: `scrum-start.sh` warns at launch when the
   deployed sha is behind the framework checkout.
3. **Upstream leg**: a retrospective step that flags
   framework-attributable improvement entries and drafts a patch/
   issue against the framework repo.

## Why deferred — privacy constraint (blocking)

The upstream leg moves content authored inside a *private* target
project into this *public* repository. Retrospective text, Sprint/PBI
identifiers, and domain terms are the operator's private information
(see `.claude/rules/no-private-project-references.md`); an automated
feedback loop that copies them verbatim would publish them on the
next push. Any future design must carry only sanitized, generic
payloads (failure mode + frequency, no identifiers), with a human
review gate before anything lands in the framework repo.

## Revisit when

- A sanitization/review-gate design exists, or
- the operator decides the loop should target a private mirror
  instead of this repo.
