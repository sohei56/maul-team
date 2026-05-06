# Common Protocol (every axis)

All 8 sub-agents follow this protocol. Add this section verbatim near
the top of every axis prompt.

## Read-only contract

- The agent must NOT modify any file. No `Write`, `Edit`, `MultiEdit`.
  Only `Read`, `Grep`, `Glob`, `Bash` for inspection (`git`, `grep`,
  `find`, `jq`, `awk`).
- The agent's output is a single Markdown report file at the path
  given in the prompt — written via `Write` ONCE at the end.

## Output file location

`/tmp/claude/cleanup-audit/<axis>-<short-name>.md` (path supplied in
prompt).

## Standard output format

```markdown
# <Axis>: <Short title>

## Summary
- N findings (high: x, medium: y, low: z)
- (axis-specific counters)

## Findings
| # | File:line | Category | Evidence | Proposal | Confidence |
| 1 | path:N | category-tag | "..." | what to do | high |
```

For redundancy axes (B1) the table can be replaced by per-cluster
sections; format:

```markdown
### Cluster 1: <topic>
- Class: cross-file | within-file | verbose-empty
- Confidence: high | medium | low
- Locations:
  - file_a:lines
  - file_b:lines
- Snippet (one truncated example):
  > ...
- Proposal: keep canonical at <file>; replace others with link.
```

## Confidence labels

| Label | Meaning |
|---|---|
| `high` | Static evidence is conclusive (grep returns 0 hits, schema rejects, etc.) |
| `medium` | Strong indicator but requires a human read of context |
| `low` | Hint only; may be a false positive |

Use `high`/`medium`/`low` per row. The synthesizer drops `low` rows
when triaging.

## Reply format (after writing the report)

Reply with:
1. Counts (one line)
2. 1-paragraph summary of biggest issues (under 150 words)

Do NOT paste the full report content into the reply — the synthesizer
reads the file directly. The summary is for at-a-glance progress.

## Already-known list (from D1)

When the parent passes a "known stale" catalog from D1, the agent must
skip re-flagging those exact items. If the agent finds a NEW stale ref
that D1 missed, it may flag it but should label the finding clearly
(e.g. "D1 missed this — confirmed-stale via ...").

## Out-of-scope guard

Each axis prompt includes "DO NOT touch other files" with a path
glob. The agent must respect this even if it spots issues outside its
glob — it can mention them in a `## Out-of-scope observations` section
at the end, but cannot edit (it's read-only anyway) and should not
re-flag at length.

## Concurrency safety

Sub-agents run in parallel and may all write to
`/tmp/claude/cleanup-audit/`. Each must use a distinct filename so
there's no clobbering. The parent allocates filenames in the prompt.
