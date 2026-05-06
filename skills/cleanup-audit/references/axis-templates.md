# Axis prompt templates

Each section below is a self-contained prompt template. Copy verbatim
when spawning the corresponding sub-agent, filling in the bracketed
slots `[REPO_PATH]`, `[D1_CATALOG]`, etc.

All templates assume the agent has read access to the working tree.
Spawn with `subagent_type: "general-purpose"`.

---

## D1 — Stale references (run FIRST, sequential)

```
You are auditing the repo at `[REPO_PATH]` for stale references to
removed concepts. READ-ONLY. Do not modify any file.

## Background
Recently removed concepts (derived from `git log --oneline -15` of
this branch):
- [SYMBOL_1] (removed in [COMMIT_SHA] — [WHY])
- [SYMBOL_2] (...)
- [...]

CRITICAL DISAMBIGUATION (project-specific): if a symbol name has
multiple meanings (e.g. `phase` exists at both project level and PBI
level), only one is removed. List which is which here:
- [DISAMBIGUATION_NOTE_IF_ANY]

## Your task
1. Run `git log --oneline -15` and `git diff [LAST_RELEVANT_SHA]..HEAD
   -- '*.md' '*.sh' '*.py' '*.json'` to confirm the removed symbols
   and discover any others.
2. Search the entire working tree for stale references to each
   removed symbol.
3. For each hit, classify:
   - `confirmed-stale`: clear residue of removed concept
   - `ambiguous`: needs human review (e.g. could be a still-valid
     overload of the same name)
   - `valid`: actually a current/correct usage (do not include)

## Output
Write to `/tmp/claude/cleanup-audit/D1-stale-refs.md`. Format per
common-protocol.md, with these section headers:

  ## Summary
  ## Removed symbols catalogued
  ## Findings
    ### Confirmed stale (table)
    ### Ambiguous (table — needs review)
  ## Cross-checks performed

After writing, reply with: total counts + 1-paragraph (under 150
words) summary of the most impactful residues.
```

---

## A1 — State / Contracts consistency

```
[Common protocol: read-only, output to /tmp/claude/cleanup-audit/A1-state-contracts.md]

## Scope (DO NOT touch other files)
- Schemas: [SCHEMA_PATHS]
- State writer scripts: [WRAPPER_PATHS]
- State guard hooks: [GUARD_HOOK_PATHS]
- Migration docs: [MIGRATION_DOC_PATHS]
- Sections of CLAUDE.md and docs/ describing state management

## Goal — find inconsistencies (NOT redundancies; that's B1):
1. Schema fields that no script writes/reads, or script writes that
   aren't in schema
2. Doc describing fields that don't exist in schema
3. Script CLI signatures (positional args, env vars) that disagree
   with doc
4. Multiple schemas claiming SSOT for the same data
5. Hook allowlist out of sync with actual writer file list

## Already known (skip re-flagging)
[D1_CATALOG]

## Output format
Categories: schema-script-drift, schema-doc-drift, cli-signature-drift,
dual-ssot, hook-allowlist-drift, other.

After writing, reply with counts + 1-paragraph summary of the most
impactful drifts.
```

---

## A2 — Agents / Skills definitions consistency

```
[Common protocol: ... A2-agents-skills.md]

## Scope
- agents/*.md — N definitions
- skills/*/SKILL.md — M skills (and skills/*/references/*.md)
- Launcher / setup scripts that reference them
- Sections of CLAUDE.md listing skills/agents
- Hooks that reference agent/skill paths

## Goal
1. Skill listed in CLAUDE.md but no SKILL.md (or vice versa)
2. Agent listed but no agents/<name>.md (or vice versa)
3. Skill/agent referenced by sibling skill/agent that doesn't exist
4. Setup script deploys files that don't exist (or fails to deploy
   files that should be)
5. SKILL.md frontmatter inconsistent with usage
6. Hook references agent/skill at moved/removed path
7. Capability descriptions that no longer match reality

## Already known (skip)
[D1_CATALOG]

## Output format
Categories: missing-definition, dangling-reference, setup-deploy-drift,
frontmatter-drift, description-drift, hook-path-drift, other.
```

---

## A3 — Workflow / Pipeline consistency

```
[Common protocol: ... A3-workflow-pipeline.md]

## Scope (project-specific — adapt to your domain)
- Workflow scripts: [LIST]
- Workflow guard hook(s): [LIST]
- Quality / completion gates: [LIST]
- Pipeline skill(s): [LIST]
- Migration docs scoped to this workflow
- CLAUDE.md sections describing the workflow
- Agents that participate

## Goal — narrative-vs-implementation drift:
1. Doc prose vs actual script behavior (preconditions, side effects,
   error codes, retry logic)
2. Skill instructions vs actual script CLI signatures
3. Hook allowlist vs scripts that actually need to perform the
   guarded operation
4. Failure-path narrative in doc vs actual error codes / kind values
5. Termination logic described vs actually implemented

## Already known (skip)
[D1_CATALOG]

## Output format
Categories: script-doc-drift, failure-path-drift, hook-allowlist-drift,
termination-logic-drift, agent-skill-drift, other.
```

---

## B1 — Markdown redundancy

```
[Common protocol: ... B1-markdown-redundancy.md]

## Scope
ALL .md files except: frozen historical plans/specs, archived docs.
Specifically include: CLAUDE.md, README.md, docs/**/*.md,
agents/*.md, skills/**/*.md.

## Goal — three classes:
1. Cross-file dup: same regulation/rule/example in 3+ files
   (2 is borderline; flag only when extracting + linking is clearly
   better)
2. Within-file dup: same point made multiple times in one file
3. Verbose-but-empty: filler (matches the project's token-efficiency
   rule if one exists)

## Method
- Pick HIGH-VALUE duplication: regulations, lifecycle diagrams,
  setup boilerplate, command examples, agent catalogs
- For each, list ALL occurrences (file:line) and propose canonical
  home + remove-from list
- Don't flag legitimate cross-references (a skill linking to
  CLAUDE.md is fine; flag only when content is COPIED)

## Already known (skip)
[D1_CATALOG]

## Output format
Per-cluster sections (NOT a flat table). Each cluster:
  ### Cluster N: <topic>
  - Class: cross-file | within-file | verbose-empty
  - Confidence: high | medium | low
  - Locations: ...
  - Snippet: short truncated example
  - Proposal: canonical + replace-with action

After writing, reply with cluster count + 1-paragraph summary.
```

---

## B2 — Shell / Python redundancy

```
[Common protocol: ... B2-code-redundancy.md]

## Scope
- All shell scripts (entry-points, lib, hooks)
- All Python sources

EXCLUDE: tests/ (test code can repeat for clarity).

## Goal
1. Duplicate / near-duplicate functions across files
2. Inline-copied helpers (helper exists in lib/, but multiple scripts
   re-implement inline)
3. Dead code / unreachable branches (functions with no callers,
   conditionals that can never fire, unused variables)
4. Logging / validation duplication that should use existing
   helper

## Method
- Shell: grep function definitions (`^[a-z_]\+\(\) {`), check for
  near-identical bodies
- Python: scan for duplicated logic
- For each finding, list locations + propose consolidation target

## Output format
Categories: duplicate-function, inline-copied-helper, dead-code,
logging-dup, other.
```

---

## C1 — Hooks dead/ineffective

```
[Common protocol: ... C1-hooks.md]

## Scope
- All hooks/*.sh
- .claude/settings.json + .claude/settings.local.json
- Any other hook registration files (e.g. setup scripts that emit
  settings.json templates)

## Goal — five classes of "dead/ineffective":
1. Unregistered hook file: script exists, no settings.json registers
2. Registered-but-orphan: settings.json registers a non-existent
   file
3. Registered-but-never-fires: matcher pattern doesn't match any
   actual tool used
4. Registered with broken matcher: malformed JSON, wrong field, etc.
5. Path drift: settings.json references hook at old path

## Method
1. Enumerate hooks/*.sh and hooks/lib/*.sh
2. Parse settings.json (jq via Bash)
3. Cross-reference each hook against registration
4. Sanity-check matchers against known tool names (Bash, Read, Edit,
   Write, Grep, Glob, Task, ...). Flag suspicious tool names.

## Output format
Two sections:
  ## Inventory (all hooks, registered? matcher, status)
  ## Findings (table)

Categories: unregistered-file, orphan-registration, broken-matcher,
path-drift, other.
```

---

## C2 — Unused scripts / agents / skills

```
[Common protocol: ... C2-unused-artifacts.md]

## Scope
- scripts/**/*.sh
- agents/*.md
- skills/*/SKILL.md AND skills/*/references/*.md

## Goal
For each artifact, determine: is it referenced from somewhere a
caller would actually invoke it?
- Scripts: referenced from another script, hook, agent, skill, or
  doc with invocation example
- Agents: spawned via `Agent(subagent_type=...)` text, referenced in
  launcher, or listed for deployment
- Skills: invoked via Skill tool examples, referenced from another
  skill, or registered for use somewhere
- references/*.md: linked from the parent SKILL.md or other docs

## Method
1. Enumerate all artifacts
2. grep entire repo for each name (basename, full path, skill name)
3. Classify:
   - well-referenced: 3+ refs → exclude from report
   - singly-referenced: 1-2 refs → include if reference is suspicious
     (test-only, doc-only, self-reference)
   - zero-reference: 0 refs → include

## Already known (skip)
[D1_CATALOG]

## Output format
Per-category inventory tables + findings table.

Categories: zero-reference, test-only-reference, doc-only-reference,
self-reference-only, other.
```

---

## Adapting the templates

When invoking on a different repo:
- Replace `[REPO_PATH]`, `[SCHEMA_PATHS]`, `[WRAPPER_PATHS]`, etc.
- Drop axes that don't apply (e.g. no contracts schemas → drop A1)
- Add ad-hoc axes if the repo has a unique structure (e.g. an "E1 —
  k8s manifest consistency" axis for a Helm chart repo)
- The protocol stays the same (read-only, fixed output format,
  confidence labels, D1-first sequencing)
