# Common protocol + 8 axis prompt templates

All sub-agents follow the common protocol below. Each axis section is
a self-contained prompt template — copy verbatim when spawning,
filling in the bracketed slots (`[REPO_PATH]`, `[STALE_REFS_CATALOG]`,
etc.).

Spawn with `subagent_type: "general-purpose"`.

---

## Common protocol (every axis)

### Read-only contract

- NO `Write` / `Edit` / `MultiEdit` except the single final report
- Inspection only: `Read`, `Grep`, `Glob`, `Bash` (`git`, `grep`,
  `find`, `jq`, `awk`)
- Output: ONE Markdown report at the path supplied in the prompt,
  written via `Write` ONCE at the end

### Standard output format

```markdown
# <Axis>: <Short title>

## Summary
- N findings (high: x, medium: y, low: z)
- (axis-specific counters)

## Findings
| # | File:line | Category | Evidence | Proposal | Confidence |
| 1 | path:N | category-tag | "..." | what to do | high |
```

For redundancy axes (`redundancy-markdown` / `redundancy-code`) the
table can be replaced by per-cluster sections — see those axis
templates for the alternate format.

### Confidence labels

- `high`: static evidence is conclusive (grep returns 0 hits, schema
  rejects, etc.)
- `medium`: strong indicator but requires a human read of context
- `low`: hint only; may be a false positive

The synthesizer drops `low` rows when triaging.

### Reply format (after writing the report)

1. Counts (one line)
2. 1-paragraph summary of biggest issues (under 150 words)

Do NOT paste full report content into the reply — the synthesizer
reads the file directly.

### Already-known list (from `stale-refs`)

When the parent passes a "known stale" catalog from `stale-refs`,
skip re-flagging those exact items. If a NEW stale ref appears that
`stale-refs` missed, flag it but label clearly: "stale-refs missed
this — confirmed-stale via ...".

### Out-of-scope guard

Each axis declares its file globs and forbids edits outside. Issues
spotted outside the glob may go in a `## Out-of-scope observations`
section at the end (no flagging at length).

### Concurrency safety

Sub-agents run in parallel and may all write into
`/tmp/claude/cleanup-audit/`. Each uses a distinct filename
(supplied by parent in the prompt).

---

## stale-refs (run FIRST, sequential)

```
You are auditing the maul-team repo at `[REPO_PATH]` for
stale references to removed concepts. READ-ONLY. Do not modify any
file.

## Background
Recently removed concepts (from `git log --oneline -15`):
- [SYMBOL_1] (removed in [SHA] — [WHY])
- [SYMBOL_2] ...

CRITICAL DISAMBIGUATION (project-specific): if a symbol name has
multiple meanings (e.g. `phase` exists at both project workflow
level and PBI lifecycle level), only one is removed. List which is
which here:
- [DISAMBIGUATION_NOTE_IF_ANY]

## Your task
1. Run `git log --oneline -15` and `git diff [LAST_RELEVANT_SHA]..HEAD
   -- '*.md' '*.sh' '*.py' '*.json'` to confirm the removed symbols
   and discover any others.
2. Search the entire working tree for stale references. Exclude
   docs/superpowers/plans/ and docs/superpowers/specs/ (frozen dated
   historical documents; residues there are expected, not stale).
3. Classify each hit:
   - `confirmed-stale`: clear residue of removed concept
   - `ambiguous`: needs human review (e.g. could be a still-valid
     overload of the same name)
   - `valid`: actually a current/correct usage (do NOT include)

## Output
Write to `/tmp/claude/cleanup-audit/stale-refs.md`. Format per common
protocol, with these sections:
  ## Summary
  ## Removed symbols catalogued
  ## Findings
    ### Confirmed stale (table)
    ### Ambiguous (table — needs review)
  ## Cross-checks performed

After writing, reply with: total counts + 150-word summary of the
most impactful residues.
```

---

## consistency-state

```
[Common protocol; output to /tmp/claude/cleanup-audit/consistency-state.md]

## Scope (DO NOT touch other files)
- Schemas: docs/contracts/scrum-state/*
- State writer scripts: scripts/scrum/*.sh, .scrum/scripts/*.sh
- State guard hook: hooks/pre-tool-use-scrum-state-guard.sh
- Migration docs: docs/MIGRATION-*.md
- CLAUDE.md "State management" section
- docs/data-model.md and other state-related docs

## Goal — find inconsistencies (NOT redundancies; that belongs to
   redundancy-markdown):
1. Schema fields no script writes/reads, or script writes that aren't
   in schema
2. Doc describing fields that don't exist in schema
3. Script CLI signatures (positional args, env vars) disagreeing with
   doc
4. Multiple schemas claiming SSOT for the same data
5. Hook allowlist out of sync with actual writer file list

## Already-known stale (skip re-flagging)
[STALE_REFS_CATALOG]

## Output categories
schema-script-drift, schema-doc-drift, cli-signature-drift,
dual-ssot, hook-allowlist-drift, other.

After writing, reply with counts + 150-word summary.
```

---

## consistency-agents-skills

```
[Common protocol; output to /tmp/claude/cleanup-audit/consistency-agents-skills.md]

## Scope
- agents/*.md (Scrum Master, Developer, sub-agents)
- skills/*/SKILL.md and skills/*/references/*.md
- Setup script: scripts/setup-user.sh
- CLAUDE.md sections listing skills/agents
- Hooks that reference agent/skill paths

## Goal
1. Skill listed in CLAUDE.md but no SKILL.md (or vice versa)
2. Agent listed but no agents/<name>.md (or vice versa)
3. Skill/agent referenced by sibling skill/agent that doesn't exist
4. setup-user.sh deploys files that don't exist (or fails to deploy
   files that should be)
5. SKILL.md frontmatter inconsistent with usage
6. Hook references agent/skill at moved/removed path
7. Capability descriptions that no longer match reality

## Already-known stale (skip)
[STALE_REFS_CATALOG]

## Output categories
missing-definition, dangling-reference, setup-deploy-drift,
frontmatter-drift, description-drift, hook-path-drift, other.
```

---

## consistency-workflow

```
[Common protocol; output to /tmp/claude/cleanup-audit/consistency-workflow.md]

## Scope
- Workflow scripts: scripts/scrum/commit-pbi.sh,
  mark-pbi-ready-to-merge.sh, merge-pbi.sh, and related wrappers
- Branch-ops guard hook: hooks/pre-tool-use-no-branch-ops.sh
- Quality / completion gates: hooks/post-tool-use-quality-gate.sh,
  hooks/stop-failure-gate.sh, related gates
- Pipeline skills: skills/pbi-pipeline/, skills/pbi-merge/,
  skills/pbi-escalation-handler/
- Migration docs scoped to PBI workflow
- CLAUDE.md "Git workflow" + "PBI status flow" sections
- agents/scrum-master.md, agents/developer.md, agents/pbi-*.md

## Goal — narrative-vs-implementation drift:
1. Doc prose vs actual script behavior (preconditions, side effects,
   error codes, retry logic)
2. Skill instructions vs actual script CLI signatures
3. Hook allowlist vs scripts that actually need the guarded operation
4. Failure-path narrative in doc vs actual error codes / `kind` values
5. Termination logic described vs actually implemented

## Already-known stale (skip)
[STALE_REFS_CATALOG]

## Output categories
script-doc-drift, failure-path-drift, hook-allowlist-drift,
termination-logic-drift, agent-skill-drift, other.
```

---

## redundancy-markdown

```
[Common protocol; output to /tmp/claude/cleanup-audit/redundancy-markdown.md]

## Scope
ALL .md files except: docs/superpowers/plans/*.md AND
docs/superpowers/specs/*.md (both are frozen dated historical
documents — same convention). Specifically include: CLAUDE.md,
README.md, docs/**/*.md, agents/*.md, skills/**/*.md,
.claude/skills/**/*.md.

## Goal — three classes:
1. Cross-file dup: same regulation/rule/example in 3+ files (2 is
   borderline; flag only when extracting + linking is clearly better)
2. Within-file dup: same point made multiple times in one file
3. Verbose-but-empty: filler matching .claude/rules/token-efficiency.md

## Method
- Pick HIGH-VALUE duplication: regulations, lifecycle diagrams, setup
  boilerplate, command examples, agent catalogs
- For each, list ALL occurrences (file:line) and propose canonical
  home + remove-from list
- Don't flag legitimate cross-references (link is OK; flag only when
  content is COPIED)

## Already-known stale (skip)
[STALE_REFS_CATALOG]

## Output format (per-cluster, NOT a flat table)
### Cluster N: <topic>
- Class: cross-file | within-file | verbose-empty
- Confidence: high | medium | low
- Locations: file:lines (all)
- Snippet: short truncated example
- Proposal: canonical home + replace-with action

After writing, reply with cluster count + 150-word summary.
```

---

## redundancy-code

```
[Common protocol; output to /tmp/claude/cleanup-audit/redundancy-code.md]

## Scope
- All shell scripts: scrum-start.sh, scripts/**/*.sh, hooks/*.sh,
  hooks/lib/*.sh
- All Python sources: dashboard/**/*.py

EXCLUDE: tests/ (test code can repeat for clarity).

## Goal
1. Duplicate / near-duplicate functions across files
2. Inline-copied helpers (helper exists in lib/, but multiple scripts
   re-implement inline)
3. Dead code / unreachable branches (functions with no callers,
   conditionals that can never fire, unused variables)
4. Logging / validation duplication that should use existing helper

## Method
- Shell: grep function definitions (`^[a-z_]\+\(\) {`), check
  near-identical bodies
- Python: scan for duplicated logic
- For each finding, list locations + propose consolidation target

## Output categories
duplicate-function, inline-copied-helper, dead-code, logging-dup,
other.
```

---

## dead-hooks

```
[Common protocol; output to /tmp/claude/cleanup-audit/dead-hooks.md]

## Scope
- All hooks/*.sh
- .claude/settings.json + .claude/settings.local.json
- scripts/setup-user.sh (emits target-project settings.json template)

## Goal — five classes of dead/ineffective:
1. Unregistered hook file: script exists, no settings.json registers
2. Registered-but-orphan: settings.json registers a non-existent file
3. Registered-but-never-fires: matcher pattern doesn't match any
   actual tool used
4. Registered with broken matcher: malformed JSON, wrong field, etc.
5. Path drift: settings.json references hook at old path

## Method
1. Enumerate hooks/*.sh and hooks/lib/*.sh
2. Parse settings.json + setup-user.sh template (jq via Bash)
3. Cross-reference each hook against registration
4. Sanity-check matchers vs known tool names (Bash, Read, Edit, Write,
   Grep, Glob, Task, ...). Flag suspicious tool names.

## Output format
Two sections:
  ## Inventory (all hooks: registered? matcher, status)
  ## Findings (table)

Categories: unregistered-file, orphan-registration, broken-matcher,
path-drift, other.
```

---

## unused-artifacts

```
[Common protocol; output to /tmp/claude/cleanup-audit/unused-artifacts.md]

## Scope
- scripts/**/*.sh
- agents/*.md
- skills/*/SKILL.md AND skills/*/references/*.md
- .claude/skills/*/SKILL.md AND .claude/skills/*/references/*.md

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

## Already-known stale (skip)
[STALE_REFS_CATALOG]

## Output categories
zero-reference, test-only-reference, doc-only-reference,
self-reference-only, other.
```
