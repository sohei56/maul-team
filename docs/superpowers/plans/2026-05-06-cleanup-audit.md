# Multi-Agent Cleanup Audit — Work Plan

**Date:** 2026-05-06
**Branch:** `refactor/status-phase-unification`
**Status:** OD batch 完了 / T1 完了 (Option C) / T2 完了 / T3 完了 / T4 完了 / T5 着手前
**Methodology:** 8-axis parallel sub-agent investigation (see `skills/cleanup-audit/`)

## Background

`refactor/status-phase-unification` ブランチで PBI pipeline の 12-value status 単一化が完了した直後、ユーザーが「全体的に意味合いを変えずに冗長・重複記述を削除したい。複数サブエージェント並列で観点分業」と要望。8軸（D1, A1〜3, B1〜2, C1〜2）でサブエージェントを発射し、85件の distinct issue を発見。約30%が「冗長」ではなく実バグ／drift であった。

## Goals

1. 8軸監査で発見した issue を tier化して系統的に解消
2. OD-1〜6 の未決事項を一掃した上で T1（実バグ）→ T2（drift）→ T3（doc redundancy）→ T4（code redundancy）→ T5（cosmetic）順に潰す
3. 監査メソドロジーを再利用可能な skill 化（別ファイル: `skills/cleanup-audit/`）

## Reference

- Synthesis 全文: `/tmp/claude/cleanup-audit/SYNTHESIS.md`（ephemeral; 必要なら永続化）
- Per-axis raw reports: `/tmp/claude/cleanup-audit/{D1,A1,A2,A3,B1,B2,C1,C2}-*.md`（ephemeral）

## Completed (OD batch)

### Open Decisions (resolved)

| OD | Decision | Files affected |
|---|---|---|
| OD-1 | A: project-level `phase` enum から `design`/`implementation` 完全削除 | state.schema.json, update-state-phase.sh, 2 fixtures, hooks.bats (multi-line), state-schema.bats, test_state_management.bats, data-model.md, migrate-legacy.sh |
| OD-2 | B: CLAUDE.md の hook 保護文言を「deployed targets only」に書き換え | CLAUDE.md |
| OD-3 | B: `pipeline_summary` schema field 完全削除 | backlog.schema.json, state-management.md TODO, data-model.md row, smoke-pbi-pipeline.md step |
| OD-4 | A: `phase1-design.md`/`phase2-impl-ut.md` → `design-stage.md`/`impl-ut-stage.md` rename | 2 git mv + SKILL.md link 更新 |
| OD-5 | A: `migrate-status-v2.sh` 削除（migration完了済前提） | script + integration test + 2 fixtures + MIGRATION docs |
| OD-6 | A: `feedback-routing.md` / `termination-gates.md` を main SKILL.md から explicit link | pbi-pipeline/SKILL.md |

### Bundled stale-ref cleanup (T2 partial)

OD batch に bundle した T2 項目:

- T2-17: `phase-gate.sh` → `status-gate.sh` (README:61, quickstart.md:132,206, MIGRATION-pbi-pipeline.md:47)
- T2-18: `test_state_management.bats:23` PBI-level `phase` 削除
- T2-19: `migrate-legacy.sh:11` `PBI_STATE_PHASE_NORMALIZE` 撤廃
- T2-20: `state-schema.bats:31-43` enum 同期（`pbi_pipeline_active` 追加）
- T2-22: CLAUDE.md `14 → 15 Ceremony Skills`, hooks 説明拡張

### Cascade cleanup (OD-1の必然的副作用)

サブエージェント flag → main thread で実施:

- `hooks/completion-gate.sh:67-91` `implementation)` case 完全削除（`pbi_pipeline_active` branch が代替）
- `hooks/status-gate.sh:11-13` 注釈の phase 例から `design`, `implementation` 削除
- `hooks/status-gate.sh:213-216` `implementation|review|pbi_pipeline_active` から `implementation` 撤去 + deny msg 修正

### Incident

サブエージェント実行中に `.claude/rules/token-efficiency.md` が誤削除されていた → `git checkout HEAD --` で復元。原因サブエージェント未特定（OD-A/B/C いずれかが `del(...)` を広範に実行した可能性）。

### Verification

| 項目 | 結果 |
|---|---|
| `bats tests/unit/ tests/lint/ tests/integration/` | **122/122 pass, 0 failures** |
| `shellcheck` (全shell scripts) | **clean** |
| Stale ref scan | 残るのは意図的な historical note のみ（`agent-interfaces.md:365` "renamed from phase-gate.sh", `MIGRATION-scrum-state-tools.md` history pointer） |

## Completed: T1 batch (Option C resolution)

**Decision:** T1-1 → **Option C** (`merge_regression` 概念を schema/script/skill から完全削除)。Sprint末 `cross-review` が comprehensive quality 検証を担う前提で、per-PBI merge は `paths_touched` 検証＋structural success のみに簡素化。

| # | 完了内容 | Files |
|---|---|---|
| T1-1 | `merge_regression` 削除 (Option C) | `merge-pbi.sh` (quality-gate ブロック削除, `ROOT` 未使用化), `mark-pbi-merge-failure.sh` (regression case 削除), `update-pbi-state.sh` (escalation_reason whitelist 縮小), `pbi-state.schema.json` (kind/escalation_reason enum + dead `report_path` 削除), `pbi-merge/SKILL.md`, `pbi-escalation-handler/SKILL.md`, `pbi-pipeline/SKILL.md`, `pbi-pipeline/references/state-management.md`, `CLAUDE.md`, `data-model.md`, `MIGRATION-scrum-state-tools.md`, `test_mark-pbi-merge-failure.bats` (regression test → rejection test), `test_update-pbi-state.bats`, `test_merge-pbi.bats` (`SCRUM_SKIP_QUALITY_GATE` 環境変数除去) |
| T1-2 | kind prefix drift 解消 | `pbi-merge/SKILL.md` Steps を `conflict`/`artifact_missing` に統一、`merge_*` (escalation_reason) との対応を明示注記 |
| T1-3 | 3-strike timing 正確化 | `pbi-merge/SKILL.md` Outputs/Steps: `merge_failure_count<3` 中は status=`in_progress_merge`、3rd で `escalated` に移行する旨を明記 |
| T1-4 | retry 時に `merge_failure_count` リセット | `pbi-escalation-handler/SKILL.md` Step 4: `update-pbi-state.sh` 引数に `merge_failure_count 0` 追加 |
| T1-5 | escalated PBI worktree cleanup ownership 明確化 | `pbi-escalation-handler/SKILL.md` Outputs + Step 6 (新設 abandon path): retry/hold/blocked は worktree 保持、abandon のみ SM が `cleanup-pbi-worktree.sh` を実行 |
| T1-6 | branch-ops regex の read-only ブロック解消 | `pre-tool-use-no-branch-ops.sh`: `git branch <name>` 検出 regex を「非ハイフン始まり」要件に変更し `-a/-d/-D/--list/-v` をパススルー |
| T1-7 | dashboard-event.sh raw jq 書き込み 文書化 | `dashboard-event.sh::update_pbi_pipelines` にコメント追加 (hook context は PreToolUse guard 対象外, wrapper 不要), `MIGRATION-scrum-state-tools.md` Known gaps #4 に追記 |
| T1-8 | install-subagents BLOCK/Can-proceed 矛盾解消 | `install-subagents/SKILL.md` Exit Criteria を「全 6 sub-agent 確認 / 不在なら BLOCKED」に書き換え |

### Verification (T1)

| 項目 | 結果 |
|---|---|
| `bats tests/unit/ tests/lint/ tests/integration/` | **122/122 pass, 0 failures** (skip 4: prerequisite-gated) |
| `shellcheck` (`scrum-start.sh`, `scripts/`, `hooks/`, `scripts/scrum/`) | **clean** |
| `ruff check dashboard/` | **clean** |

### Side effects (T1 incidental)

- `pbi-state.schema.json` から dead `report_path` フィールド削除 (regression 専用だった)
- `merge-pbi.sh` 未使用化した `ROOT` 変数削除
- `tests/unit/scrum-state/test_merge-pbi.bats` から dead `SCRUM_SKIP_QUALITY_GATE` 環境変数削除

## Completed: T2 batch (Drift Fixes)

OD batch で T2-5/11/13/17〜22 解消済。本バッチで残全 T2 解消。

| # | 完了内容 | Files |
|---|---|---|
| T2-1〜3 | wire | 各 skill `## Steps` に `update-state-phase.sh` / `update-sprint-status.sh` / `set-sprint-developer.sh` 明示呼び出しを追加 (`requirements-sprint`, `sprint-planning`, `cross-review`, `sprint-review`, `retrospective`, `integration-sprint`, `spawn-teammates` SKILL.md + `scrum-master.md` Sprint Phase Transition Rule) |
| T2-4 | `set-backlog-item-field.sh` 新設 (sprint_id / implementer_id / review_doc_path / catalog_targets フィールド対応; 16 bats tests pass), `sprint-planning/SKILL.md` step 9 + 10.2 を新 wrapper 経由に変更, `cross-review/SKILL.md` step 11 同, `MIGRATION-scrum-state-tools.md` mapping table + Known gaps 更新, `docs/contracts/scrum-state/README.md` write-script 表更新 |
| T2-6 | `docs/contracts/state-schemas.json` 削除 (336 行; ランタイム参照ゼロ) |
| T2-7 | `data-model.md:182` `Developer.status` enum から `idle` 削除, dashboard-only `unknown` 注記追加 |
| T2-8 | `data-model.md` Sprint table に `base_sha`, `base_sha_captured_at` 行追加; `type` enum から legacy `requirements` 削除; `status` に `failed` 追加 |
| T2-9 | `data-model.md:398` communication type enum を `communications.schema.json` SSOT と同期 |
| T2-10 | `MIGRATION-scrum-state-tools.md` `phase_transition` 段落 rephrase (max_events eviction 説明に置換) |
| T2-12 | `append-pbi-log.sh` whitelist を `init\|design\|impl_ut\|complete\|escalated` → `init\|design\|pbi_review\|ut_run\|complete\|escalated` に更新 (実 caller である pbi-pipeline references の `pbi_review`/`ut_run` を受理); error msg + arg 名 (`<phase>` → `<stage>`) 整理; tests 追加 (legacy `impl_ut` reject + 新 stage accept) |
| T2-14 | `pbi-merge/SKILL.md` Step 1 + Strict Rule, `scrum-master.md` Concurrency 注記の `flock` 文言を `mkdir`-based directory lock に修正 |
| T2-15 | `developer.md` Escalation reason に `requirements_unclear`, `catalog_lock_timeout` 追加; SM-side merge reasons (`merge_conflict`, `merge_artifact_missing`) を Developer 圏外として明示 |
| T2-16 | `developer.md:111` `.scrum/reviews/` ownership 修正 (write → read-only context; SM `cross-review` skill 所有) |
| T2-21 | 既に in-repo (`migrate-legacy.sh` 冒頭 + 実行時 WARNING printf) |

### Verification (T2)

| 項目 | 結果 |
|---|---|
| `bats --recursive tests/unit/ tests/lint/ tests/integration/` | **305/305 pass, 0 failures** (skip 4: prerequisite-gated) |
| `shellcheck` (`scrum-start.sh`, `scripts/`, `hooks/`, `scripts/scrum/`) | **clean** |
| `ruff check dashboard/` | **clean** |

## Completed: T3 batch (Markdown Redundancy)

| # | 完了内容 | Files |
|---|---|---|
| T3-1 | 12-value status enum dedup → data-model.md canonical | `skills/pbi-pipeline/SKILL.md`, `skills/pbi-pipeline/references/state-management.md`, `agents/scrum-master.md`, `agents/developer.md` |
| T3-2 | requirements.md within-file 12-state x3 → x1 (Q&A 2026-02-25 canonical) | `docs/requirements.md` |
| T3-3 | structure tree 3-way → CLAUDE.md canonical (quickstart STALE skills/design+implementation 削除) | `docs/quickstart.md`, `CONTRIBUTING.md` |
| T3-4 | setup boilerplate `pip install textual watchdog` Assumptions 重複削除 (SC-007 cross-ref) | `docs/requirements.md` |
| T3-5 | test/lint commands → CONTRIBUTING.md canonical, quickstart pointer | `docs/quickstart.md` |
| T3-6 | sub-agent catalog 7-way → docs/contracts/sub-agents.md canonical, 9 sub-agent one-liners 集約 | `CLAUDE.md`, `CONTRIBUTING.md`, `docs/quickstart.md`, `docs/requirements.md` |
| T3-7 | CLAUDE.md merge protocol → pbi-merge skill pointer | `CLAUDE.md` |
| T3-8 | codex-impl-reviewer Processing Flow → "Identical to codex-design-reviewer." pointer (codex-ut-reviewer pattern と統一) | `agents/codex-impl-reviewer.md` |
| T3-9 | architecture.md R7 inline phase diagram 削除 → data-model.md pointer のみ | `docs/architecture.md` |
| T3-10 | quickstart.md "Key Concepts" stale section → 6-bullet pointer block + stale "14 skills" → "all installed" | `docs/quickstart.md` |
| T3-11 | MIGRATION-pbi-pipeline.md archival (Historical callout + concept mapping のみ; ~30行削減) | `docs/MIGRATION-pbi-pipeline.md`, `docs/quickstart.md` |
| T3-extra | sub-agent-prompts.md → slot-fillers only (B1 Cluster 10, 計画には未記載) | `skills/pbi-pipeline/references/sub-agent-prompts.md` |

### Verification (T3)

| 項目 | 結果 |
|---|---|
| `bats --recursive tests/unit/ tests/lint/ tests/integration/` | **305/305 pass, 0 failures** (skip 4: prerequisite-gated) |
| `shellcheck` | **clean** |
| `ruff check dashboard/` + `ruff format --check` | **clean** |

### Skipped (B1 borderline, 着手意図的見送り)

- T3-12 (Cluster 8 severity DRY): agent definition は self-contained prompt; 重複は intentional。`docs/contracts/sub-agents.md` への Severity contract 集約は、意義が surfacingにとどまるため見送り。
- T3-13 (Cluster 13 README "AI-Specific Adaptations"): marketing prose; tightening は approachability の犠牲が大きく見送り。

## Completed: T4 batch (Code Redundancy + Dead code)

| # | 完了内容 | Files |
|---|---|---|
| T4-1 | inline `date -u +"%Y-%m-%dT%H:%M:%SZ"` 4 コピー → `_iso_utc_now` | `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `freeze-sprint-base.sh`, `append-pbi-log.sh` (atomic.sh sourcing 追加) |
| T4-3 | `ensure_dashboard_file` / `append_dashboard_event` 重複 → 新 `hooks/lib/dashboard.sh` | `hooks/lib/dashboard.sh` (新設), `hooks/stop-failure.sh`, `hooks/dashboard-event.sh` |
| T4-4 | merge-pbi.sh inline mkdir lock → `_acquire_lock` 経由 | `scripts/scrum/merge-pbi.sh` (atomic.sh sourcing + `SCRUM_LOCK_TIMEOUT:=30` で旧 30s default 維持) |
| T4-5 | `get_pbi_status` / `pbi_in_backlog` 重複 → `scripts/scrum/lib/queries.sh` 新設 + `hooks/lib/validate.sh::get_pbi_status_from_backlog` 追加 | `scripts/scrum/lib/queries.sh` (新設), `mark-pbi-merged.sh`, `merge-pbi.sh`, `cleanup-pbi-worktree.sh`, `hooks/lib/validate.sh`, `hooks/completion-gate.sh`, `hooks/dashboard-event.sh` |
| T4-6 | hook stderr `[name] LEVEL: msg` 6コピー → `stderr_log` (validate.sh) | `hooks/lib/validate.sh`, `hooks/pre-tool-use-{scrum-state-guard,no-branch-ops,path-guard}.sh`, `hooks/quality-gate.sh`, `hooks/completion-gate.sh` |
| T4-7 | `migrate-legacy.sh::validate_json` + `iso_now` → `_validate_against_schema` + `_iso_utc_now` | `scripts/scrum/migrate-legacy.sh` (errors.sh + atomic.sh sourcing), `scripts/scrum/lib/atomic.sh` (`_validate_against_schema` の stderr 抑制を解除し caller に validation error 詳細を伝播) |
| T4-Dead1 | `has_enabled_catalog_entry` 削除 | `hooks/status-gate.sh` |
| T4-Dead2 | `ask` 削除 | `hooks/status-gate.sh` |
| T4-Dead3 | statusline.sh 不要 stdin read 削除 | `scripts/statusline.sh` (SC2034 disable も同時除去) |

T4-2 は OD-5 で `migrate-status-v2.sh` 自体が削除されたため不要。

### Verification (T4)

| 項目 | 結果 |
|---|---|
| `bats --recursive tests/unit/ tests/lint/ tests/integration/` | **305 pass, 0 fail** (skip 6: prerequisite-gated 4 + macOS flock 2) |
| `shellcheck` (`scrum-start.sh`, `scripts/`, `scripts/lib/`, `scripts/scrum/`, `scripts/scrum/lib/`, `hooks/`, `hooks/lib/`) | **clean** |
| `ruff check dashboard/` + `ruff format --check` | **clean** |

### Side effects (T4 incidental)

- `_validate_against_schema` (atomic.sh) が validator stderr を漏らすようになり、atomic_write/migrate-legacy.sh の `fail E_SCHEMA` メッセージに具体的な validation error が含まれるようになった (success 時は stdout 抑制で chatter 防止)
- `hooks/lib/dashboard.sh` 新設、`scripts/scrum/lib/queries.sh` 新設 — どちらも `setup-user.sh` の `copy_tree "$PROJECT_ROOT/{hooks,scripts/scrum}/lib/*.sh" ...` で deployed projects に自動配布される

## Remaining Work

### T5: Cosmetic (~6)

- `hooks/lib/codex-invoke.sh` を `agents/lib/` か `scripts/lib/` へ移動
- `dashboard-event.sh::shorten_id` を Helpers ブロックへ
- `pbi-pipeline/SKILL.md:80-87` Markdown table → bullet list
- `requirements-sprint/SKILL.md` に Roles section 追加（SM/Dev step分担）
- `pbi-state.schema.json` description に「`merge_failure.kind` (no prefix) vs `escalation_reason` (`merge_*` prefix)」一行注記
- C1-H2: `setup-user.sh` PostToolUse matcher の `Agent` 妥当性検証 → 削除可なら削除
- C1-H3: `dashboard-event.sh` の `FileChanged` ハンドラ追加 or registration 削除
- C1-H5: `hooks/lib/codex-invoke.sh` 配置（T5 と重複）

## Task Tracking

TaskList #14 (T1) → #15 (T2) → #16 (T3) → #17 (T4) → #18 (T5) で連結済。各タスクは前タスクで blocked。

## Decision Log

- 2026-05-06: 8軸並列調査着手、D1先行→7体並列実行
- 2026-05-06: OD-1〜6 全項目 user 決定、OD batch 並列実行・全 pass
- 2026-05-06: T1-1 user 決定 = **Option C** (merge_regression 概念完全削除)
- 2026-05-06: T1 batch (T1-1〜8) 完了、bats 122/122 + shellcheck + ruff clean
- 2026-05-06: T2 batch (T2-1〜21 全項目、T2-5/11/13/17〜22 は OD で先行解消) 完了、bats 305/305 + shellcheck + ruff clean。`set-backlog-item-field.sh` 新設で sprint-planning step 9/10.2 が初めて runtime-safe に
- 2026-05-07: T3 batch (T3-1〜11 + T3-extra; T3-12/13 は B1 borderline で意図的見送り) 完了、12 commits、bats 305/305 + shellcheck + ruff clean。canonical 集約先: `docs/data-model.md` (PBI status), `docs/contracts/sub-agents.md` (sub-agent catalog), `CLAUDE.md` (project structure tree), `CONTRIBUTING.md` (dev test/lint), `skills/pbi-merge/SKILL.md` (merge protocol)
- 2026-05-07: T4 batch (T4-1/3/4/5/6/7 + T4-Dead1/2/3; T4-2 は OD-5 で消滅) 完了、8 commits、bats 305 pass + shellcheck + ruff clean。新設 lib: `scripts/scrum/lib/queries.sh`, `hooks/lib/dashboard.sh`。`_validate_against_schema` の stderr 解放により validation error が caller に伝播するようになった (atomic_write の `fail E_SCHEMA` メッセージも改善)
