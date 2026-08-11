# Scrum artifact policy

This table is the complete artifact lifecycle policy. Fixed-path readers keep
using the paths shown here; cleanup must not relocate PBI, review, or Product
Owner evidence.

| Path | Writer / readers | Class | Include in resume | Retention / cleanup |
|---|---|---|---|---|
| `.scrum/state.json`, `.scrum/sprint.json`, `.scrum/backlog.json`, `.scrum/test-results.json`, `.scrum/po/decisions.json`, `.scrum/improvements.json`, `.scrum/communications.json`, `.scrum/attention.json` | Existing Scrum wrappers / existing gates, skills, dashboard, status line | Hot | Yes, through the resume summary when relevant | Keep at the fixed path; existing lifecycle writers are authoritative. |
| `.scrum/pbi/<pbi-id>/**` | Existing PBI pipeline wrappers and agents / existing pipeline, review, merge, and audit readers | Hot | Only active or escalated PBI summary/evidence | Keep at fixed paths. Do not move or delete PBI evidence. Per-worktree disposable environments and generated output are the sole exception below. |
| `.scrum/reviews/**`, `.scrum/po/**` | Existing review and PO ceremonies / completion gates, Sprint Review, audit, and operators | Hot | Latest decision/finding summary and links when relevant | Keep at fixed paths. Do not move or delete review or PO evidence. |
| `.scrum/sprint-history.json` | `append-sprint-history.sh` / existing gates, watchdog, dashboard, status line, reports | Archive | Latest completed Sprint summary only | Append-only at its fixed path. Never rewritten by artifact cleanup. |
| `.scrum/sprint-index.md` | `generate-sprint-index.sh` / humans and future resume-summary producer | Archive | Yes: compact latest-Sprint row/link, not source evidence | Regenerate at Sprint end. It is a derived index, not an authoritative reader input. |
| `.scrum/rollups/<run-id>/{stdout,stderr}` when sibling `status` is `success` or `passed` | Rollup runner / troubleshooting until success is recorded | Remove | No | Remove successful raw streams; retain failed/incomplete streams. |
| `.scrum/worktrees/<pbi-id>/{.venv,.cache,.pytest_cache,.mypy_cache,.ruff_cache,__pycache__,build,dist,out}` | Build/test tools / build/test tools | Remove | No | Remove generated environment, cache, and build output. Never traverse the worktree's `.scrum` symlink. |
| `.scrum/framework-issues/<draft>.md` with sibling metadata `status=posted` | `draft-framework-issue.sh` / operator before posting | Remove | No; resume may use the metadata URL | Remove the posted body because the public issue is the durable copy; keep the `.meta` sidecar and `posted_url`. |
| `.scrum/*.log`, `.scrum/logs/*.log` | Runtime hooks/daemons / operator troubleshooting | Hot | No, except a bounded error summary | When over the configured byte ceiling, keep only the newest bytes at the same fixed path. Do not apply this rule to PBI/review/PO evidence logs. |
| `.scrum/locks/*.lock.d` with numeric `owner.pid` | Scrum wrappers / lock owner and cleanup | Remove | No | Remove only after the minimum age and either `kill -0` explicitly reports no such process or a portable `ps` fallback confirms absence. Permission-denied, missing-tool, malformed, live, or otherwise unverifiable owners are retained. |
| `.scrum/archive/**` | Future layout-v2 resolver / future resolver readers | Archive | Through the resolver only | Reserved. Do not populate until every fixed-path reader incrementally uses a resolver; seal completed Sprints only, never active/escalated PBIs, and never auto-migrate existing projects. |
| `stock-bo-monitoring-system/.scrum/**` | Fixture/project-owned | Hot | No | Protected fixture boundary: artifact tools must perform absolutely no write, move, truncation, or deletion here. |
