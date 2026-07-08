---
name: no-private-project-references
description: >
  Public documentation in this framework repository must not name or
  identify the user's private downstream projects (target projects
  that adopted this framework). Project codenames, repo names, Sprint
  IDs, and PBI IDs from those projects are treated as private — the
  framework is published, but those examples are not.
paths:
  - "skills/**"
  - "docs/**"
  - "agents/**"
  - "rules/**"
  - ".claude/rules/**"
  - "hooks/**/*.md"
  - "scripts/**/*.md"
  - "dashboard/**/*.md"
  - "README*.md"
  - "CLAUDE.md"
---

# No private project references in public docs

**Scope.** This rule lives under `.claude/rules/` in the framework
repo and is **not** copied to downstream target projects by
`setup-user.sh` (which only deploys `rules/*.md`). It governs only
this repository's own published surfaces.

This repository is the **published** `maul-team` framework.
The Scrum team it spawns runs inside **other** repositories ("target
projects") whose identifiers, retrospective findings, and Sprint /
PBI IDs are the user's private information. They must not appear in
this repo's documentation, skill text, agent prompts, or rules.

This applies regardless of whether the identifier is public on its
own — once it is paired here with framework-internal failure modes
("project X retrospectives showed cross-review failed 5 Sprints in a
row"), the pairing itself is the private signal.

## What counts as a private reference

- **Codenames / repo names** of target projects.
- **Sprint IDs from target projects** (any specific Sprint number or
  Sprint ID tied to a real downstream project) — including when only
  the Sprint number is named.
- **PBI IDs from target projects** (any specific PBI ID tied to a
  real downstream project).
- **Domain-specific business terms** that only appear in those
  projects (e.g., naming an order engine, an auction scraper, a
  monitoring bot when the framework itself is domain-agnostic).
- **Quoted private retrospective findings** ("their Sprint 24 retro
  said …") even if the project name is stripped.

`sprint-001` / `sprint-002` / `imp-001` style **placeholder** IDs in
spec / schema / example payloads are fine — they are not from any
real project. Likewise the framework's own integration-test fixtures
under `tests/fixtures/` are framework-owned and not target-project
data.

## How to phrase target-project evidence generically

When a failure-mode argument needs the *frequency* of past occurrence
as load-bearing evidence (e.g., "this rule was pinned and still
failed → therefore Opus override"), preserve the count and drop the
identifiers:

- ❌ "<project-A> Sprint NN (`<pbi-id>`): 11-file conflict across 5
  PBIs"
- ✅ "Observed in a target project: an 11-file conflict across 5 PBIs
  in a single Sprint"

- ❌ "Recurred across 4 sprints in 2 projects (<project-A> Sprint NN
  `<pbi-id-a>`, Sprint NN `<pbi-id-b>`, …)"
- ✅ "Recurred across 4 Sprints in 2 target projects"

- ❌ "Failure logged in <project-B> retros (`<pbi-id-1>` /
  `<pbi-id-2>` / `<pbi-id-3>` …)"
- ✅ "Target-project retrospectives showed this failure 5 Sprints in a
  row"

When the identifier *itself* is the load-bearing part (e.g., "go read
this PBI's design doc"), the evidence belongs in the user's private
notes or a memory entry, not in this repo. Cut the example and keep
only the rule.

## Before adding new doc / skill / agent text

Before committing prose under any path listed in `paths:` above, scan
your additions for:

1. Any project codename or repo name that is not this framework
   itself.
2. Any Sprint / PBI ID that is not a `sprint-NNN` / `imp-NNN` style
   generic placeholder.
3. Any specific dated retro finding that could only come from one
   real Sprint.

If any of the above slips in, generalize it as shown above before
saving.

## Why

- This repository is public. Target-project identifiers and retros
  are not — they belong to the operator, not to the framework.
- Even partial leaks (a Sprint number + a failure mode) are enough to
  fingerprint a private project to anyone who also has read access
  to it.
- Generic phrasing ("a target project", "recurred across 4 Sprints in
  2 target projects") preserves the *evidentiary weight* of the rule
  without exposing the source.

See also: [[scrum-context]] for the framework-level team map and
SSOT locations (which are framework-internal and therefore fine to
document here).
