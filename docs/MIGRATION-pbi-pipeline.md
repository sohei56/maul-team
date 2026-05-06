# Migration Guide: PBI Pipeline (legacy design + implementation flow → pbi-pipeline)

## Summary

Per-PBI workflow changed from "Developer runs design then implementation
in one session" to "Developer conducts a multi-session pipeline of
specialized sub-agents". See spec at
`docs/superpowers/specs/2026-05-02-pbi-pipeline-design.md`.

## In-flight Sprint handling

If you are mid-Sprint when upgrading:

1. Complete the current Sprint on the legacy flow.
   - The legacy `design` and `implementation` skill files are removed
     from this version. If your in-flight Sprint requires them, copy
     them from the prior commit:

     ```bash
     git show <previous-commit>:skills/design/SKILL.md > skills/design/SKILL.md
     git show <previous-commit>:skills/implementation/SKILL.md > skills/implementation/SKILL.md
     ```

2. From the next Sprint, adopt the new flow:
   - Sprint Planning records `catalog_targets` per PBI in
     `backlog.json` (see `skills/sprint-planning/SKILL.md`).
   - Developer invokes `pbi-pipeline` per PBI.

## Concept mapping

| Legacy concept | New equivalent |
|---|---|
| Developer writes code via `implementation` skill | Developer is a conductor; `pbi-implementer` sub-agent writes code |
| Tests written by Developer alongside impl | `pbi-ut-author` sub-agent writes tests independently from impl source (black-box) |
| Catalog design at `docs/design/specs/...` | UNCHANGED — still the source of truth for permanent component design |
| (no concept) | `.scrum/pbi/<pbi-id>/design/design.md` — PBI working design (transient) |
| Design review at SM cross-review | Two layers: per-PBI design review (codex-design-reviewer) + Sprint-end cross-review (unchanged) |
| Test coverage tracked manually | Coverage measured by real tooling per Round; gated by C0/C1 thresholds |

## Required project changes

- Add `.scrum-config.example.json` to your project; create
  `.scrum/config.json` based on it (gitignored).
- For partial-C1 languages (Go, Rust, Bash), set `c1_threshold` in
  `.scrum/config.json`; ad-hoc relaxation forbidden.
- Update `.claude/settings.json` to register
  `hooks/pre-tool-use-path-guard.sh` after `status-gate.sh` (handled
  automatically by `setup-user.sh`).

## Verifying the upgrade

Run the manual smoke test: `tests/manual/smoke-pbi-pipeline.md`.
