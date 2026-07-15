# Migration Guide: PBI Pipeline (legacy design + implementation skills → pbi-pipeline)

> **Historical.** The legacy `skills/design/` and `skills/implementation/`
> folders were removed when the pbi-pipeline skill replaced them. This
> file remains as a conceptual orientation for readers encountering
> the legacy skills in old commits or downstream forks. New
> installations follow `setup-user.sh` and do not touch the legacy
> flow.

## Concept mapping

| Legacy concept | New equivalent |
|---|---|
| Developer writes code via `implementation` skill | Developer is a conductor; `pbi-implementer` sub-agent writes code |
| Tests written by Developer alongside impl | `pbi-ut-author` sub-agent writes tests independently from impl source (black-box) |
| Catalog design at `docs/design/specs/...` | UNCHANGED — still the source of truth for permanent component design |
| (no concept) | `.scrum/pbi/<pbi-id>/design/design.md` — PBI working design (transient) |
| Design review at SM cross-review only | Per-PBI design review (codex-design-reviewer) + Sprint-end cross-review |
| Test coverage tracked manually | Coverage measured by real tooling per Round; gated by C0/C1 thresholds |

For the source-of-record spec, see
`docs/superpowers/specs/2026-05-02-pbi-pipeline-design.md`. For the
related JSON wrapper / status-unification migration, see
[MIGRATION-scrum-state-tools.md](MIGRATION-scrum-state-tools.md).
