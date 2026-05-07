# Sub-Agent Prompt Templates

Schema-first prompts the Developer (conductor) constructs when spawning
each sub-agent via the `Agent` tool. Each prompt provides only the
runtime slot-fillers (PBI id, round number, paths, prior review).
Constraints (path guards, output envelopes, severity levels, "Does
NOT receive" boundaries) live in the corresponding agent definition
under `agents/` and are not restated here. All sub-agents must end
output with the JSON envelope from spec 4.1.

## Common envelope reminder (append to every prompt)

```text
End your response with a single JSON code block matching this schema:

{
  "status": "pass | fail | error",
  "summary": "<one-line summary>",
  "verdict": "PASS | FAIL | null",
  "findings": [
    {
      "signature": "<file>:<line_start>-<line_end>:<criterion_key>",
      "severity": "critical | high | medium | low",
      "criterion_key": "<from fixed enum>",
      "file_path": "<path>",
      "line_start": <int>,
      "line_end": <int>,
      "description": "<text>"
    }
  ],
  "next_actions": ["<action>"],
  "artifacts": ["<path>"]
}
```

## pbi-designer prompt

```text
You are pbi-designer for {pbi_id}. Author the PBI working design doc.

PBI assignment:
{paste backlog.json entry for {pbi_id}}

Inputs:
- requirements.md: <path>
- catalog-config.json: docs/design/catalog-config.json
- Related catalog specs (read-only references):
  - <path1>
  - <path2>
{if Round n>=2:}
- Prior design review (address every Critical/High finding):
  - .scrum/pbi/{pbi_id}/design/review-r{n-1}.md

Write the design to:
  .scrum/pbi/{pbi_id}/design/design.md

On catalog-lock timeout, exit with status=error, escalation_reason
catalog_lock_timeout.

{common envelope reminder}
```

## codex-design-reviewer prompt

```text
You are codex-design-reviewer for {pbi_id} Round {n}. Independent
critical review of the PBI design doc.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Related catalog specs (consistency check):
  - <path1>
- requirements.md: <path>

Output to: .scrum/pbi/{pbi_id}/design/review-r{n}.md

{common envelope reminder}
```

## pbi-implementer prompt

```text
You are pbi-implementer for {pbi_id} Round {n}. Implement source code
per the design doc.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
{if Round n>=2:}
- Feedback from prior round (address every item):
  - .scrum/pbi/{pbi_id}/feedback/impl-r{n}.md

Write source code to project's normal implementation paths (e.g., src/).

{common envelope reminder}
```

## pbi-ut-author prompt

```text
You are pbi-ut-author for {pbi_id} Round {n}. Author unit tests
strictly from the design doc's `Interfaces` section.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
{if Round n>=2:}
- Feedback from prior round (address every item):
  - .scrum/pbi/{pbi_id}/feedback/ut-r{n}.md
- Prior coverage report (gap reference):
  - .scrum/pbi/{pbi_id}/metrics/coverage-r{n-1}.json

Write tests to project's normal test paths (e.g., tests/).

{common envelope reminder}
```

## codex-impl-reviewer prompt

```text
You are codex-impl-reviewer for {pbi_id} Round {n}. Independent review
of implementation source against the design doc only.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Implementation files:
  - <path1>
  - <path2>
- requirements.md: <path>

Output to: .scrum/pbi/{pbi_id}/impl/review-r{n}.md

{common envelope reminder}
```

## codex-ut-reviewer prompt

```text
You are codex-ut-reviewer for {pbi_id} Round {n}. Independent review
of tests + coverage against the design doc only.

Inputs:
- Design doc: .scrum/pbi/{pbi_id}/design/design.md
- Test files:
  - <path1>
- Coverage report: .scrum/pbi/{pbi_id}/metrics/coverage-r{n}.json
- Pragma audit: .scrum/pbi/{pbi_id}/metrics/pragma-audit-r{n}.json
- requirements.md: <path>

Output to: .scrum/pbi/{pbi_id}/ut/review-r{n}.md

{common envelope reminder}
```
