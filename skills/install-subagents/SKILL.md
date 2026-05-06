---
name: install-subagents
description: >
  Select and verify project-managed sub-agents for PBI work.
  Developers invoke after receiving PBI assignments.
disable-model-invocation: false
---

## Inputs

- PBI assignment (backlog.json → assigned PBI details)
- Sub-agent definitions in `agents/` directory

## Outputs

- Confirmation of available sub-agents
- sprint.json → developers[].sub_agents (runtime: actually-used agents only)

## Required Sub-Agents (PBI Pipeline)

Verify these 6 sub-agents exist with valid YAML frontmatter at
`.claude/agents/<name>.md`:

- `pbi-designer`
- `pbi-implementer`
- `pbi-ut-author`
- `codex-design-reviewer`
- `codex-impl-reviewer`
- `codex-ut-reviewer`

Missing required → BLOCK (escalate to SM, do not proceed to PBI work).

## Steps

1. Analyze PBI→determine specialist needs
2. Verify ALL required sub-agents exist:
   ```bash
   for name in pbi-designer pbi-implementer pbi-ut-author \
               codex-design-reviewer codex-impl-reviewer codex-ut-reviewer; do
     [ -f ".claude/agents/$name.md" ] || { echo "MISSING REQUIRED: $name"; exit 1; }
   done
   ```
3. Verify YAML frontmatter on each (yq eval '.name' or equivalent).
4. During pbi-pipeline execution→invoke via
   `Agent(subagent_type="<name>")`. Record only actually-used agents in
   sprint.json.

## Graceful Degradation

- Required sub-agent files missing → BLOCK (cannot proceed; SM must
  install them).

Ref: FR-019

## Exit Criteria

- All 6 required sub-agents verified present (per "Required Sub-Agents"
  list above) with valid YAML frontmatter
- BLOCKED if any required sub-agent is missing
