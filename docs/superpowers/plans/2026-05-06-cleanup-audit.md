# Multi-Agent Cleanup Audit — Work Plan

**Date:** 2026-05-06
**Branch:** `refactor/status-phase-unification`
**Status:** OD batch 完了 / T1 完了 (Option C) / T2 着手前
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

## Remaining Work

### T2: Drift Fixes (~13 残)

OD batch でT2-17〜22 を解消済。残：

- **2a Wiring gaps**: T2-1〜3（`update-state-phase.sh`, `update-sprint-status.sh`, `set-sprint-developer.sh` の caller 確認 → wire or delete）, T2-4 (`set-backlog-item-field.sh` 新設要), T2-5 解消済 (OD-5)
- **2b Schema drift**: T2-6 (legacy `state-schemas.json` 削除), T2-7〜10 (data-model.md 修正), T2-11 解消済 (OD-3), T2-12 (`append-pbi-log.sh` の phase arg 12-value化 or 別vocabとして文書化)
- **2c Doc-claim drift**: T2-13 解消済 (OD-2), T2-14 (`mkdir`-lock 文言修正), T2-15 (developer.md escalation reasons 追加), T2-16 (developer.md `.scrum/reviews/` ownership 修正)

### T3: Markdown Redundancy (13 clusters)

優先順（B1 cluster番号）:
1. T3-1: 12-value status enum (11箇所→data-model.md canonical)
2. T3-2: requirements.md within-file 3x→1x
3. T3-3: structure tree 3-way (quickstart STALE)
4. T3-4: setup boilerplate 3-way
5. T3-5: test/lint commands 3-way
6. T3-6: sub-agent catalog 7-way
7. T3-7: PBI merge-failure matrix 5-way
8. T3-8: codex review processing flow
9. T3-9: project workflow phase enum 3-way
10. T3-10: quickstart.md "Key Concepts" stale
11. T3-11: MIGRATION-pbi-pipeline.md archival
12. T3-12,13: minor

各 cluster は1PR想定。

### T4: Code Redundancy (17 + 3 dead code)

- **High-leverage 必須:**
  - T4-1: ISO timestamp helper 8コピー → `_iso_utc_now` に集約
  - T4-3: `stop-failure.sh` の `ensure_dashboard_file`/`append_dashboard_event` を `hooks/lib/` に移動
  - T4-4: `merge-pbi.sh` inline lock → `_acquire_lock` 公開化
  - T4-5: `get_pbi_status` 4コピー → `lib/queries.sh` 新設
  - T4-6: hook stderr_log 6コピー → `validate.sh` に集約
  - T4-7: `migrate-legacy.sh::validate_json` → `lib/atomic.sh::_validate_against_schema`
- **削除確定 dead code:**
  - `hooks/status-gate.sh::has_enabled_catalog_entry`
  - `hooks/status-gate.sh::ask`
  - `scripts/statusline.sh::session_json` の不要 stdin read
- **Out-of-scope だが OD-5 で消滅:** T4-2 (`migrate-status-v2.sh` の dedupe — script 自体削除済)

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
