# Multi-Agent Cleanup Audit (round 2) — Work Plan

**Date:** 2026-05-07
**Branch:** `fix/merge-pbi-state-loss` (現在ブランチ。実装作業時にもこのまま、もしくは派生ブランチを切る判断を冒頭で行う)
**Status:** OD batch decided / 全 tier pending (実装は次セッションで実施)
**Methodology:** 8-axis parallel sub-agent investigation (`.claude/skills/cleanup-audit/`)
**Source synthesis:** `/tmp/claude/cleanup-audit/SYNTHESIS.md`
**Per-axis raw reports:** `/tmp/claude/cleanup-audit/{stale-refs,consistency-{state,agents-skills,workflow},redundancy-{markdown,code},dead-hooks,unused-artifacts}.md`

## Background

直近の主要変更:
- e93c729 dashboard `pbi_pipelines` projection + Agents column 撤去
- 2d78328 `.scrum/` tracked化に伴う state.json loss 修正
- 3915682 `hooks/lib/dashboard.sh` 抽出 + cleanup-audit skill 追加
- d049a45 `get_pbi_status_from_backlog` 復元

これらを踏まえ 8軸監査を再実行。**64件 raw → 52件 distinct**、約20%が実バグ (T1 10件)。前回 round (2026-05-06) と異なり、今回は構造バグ2系統が支配的:
- (a) hook が SSOT ラッパーをバイパスしてスキーマ違反イベントを書込→ダッシュボードが沈黙
- (b) `completion-gate.sh` が Developer の正規終了 status `in_progress_merge` をハードブロック

## Goals

1. OD-1〜OD-8 を実装に落とし、依存する T1/T2 を一括解消
2. T1 (実バグ) → T2 (drift) → T3 (markdown 冗長) → T4 (code 冗長) → T5 (cosmetic) の順で潰す
3. 各 PR を canonical-file 単位でバッチ化 (前 round の T3 で確立した方法)

## Open Decisions (resolved)

| OD | 決定 | 影響範囲 (実装側) |
|---|---|---|
| **OD-1** | **B+C**: `state.json.active_pbi_pipelines[]` フィールドを schema/読者から削除し、必要な場面では `backlog.json` から `select(.status \| startswith("in_progress_"))` で導出 | `state.schema.json`, `completion-gate.sh:158`, `session-context.sh:41`, `pbi-pipeline/references/state-management.md:139,147`, data-model.md, MIGRATION docs |
| **OD-2** | **A**: `hooks/dashboard-event.sh` + `hooks/stop-failure.sh` を `.scrum/scripts/append-{dashboard-event,communication}.sh` シェルアウトに改修。`hooks/lib/dashboard.sh` の inline 書き込み helper は撤去 | hooks 2本 + lib削減 + scrum-state-guard exemption の整理 |
| **OD-3** | **スモークテスト即実施**: `TaskCompleted`, `TeammateIdle`, `SubagentStart`, `FileChanged`, `Agent` matcher が実際に発火するか検証。結果次第で OD-5 と T1-3 並走バグの分岐を決める | 検証用スクリプト (一時) + `setup-user.sh` + `dashboard-event.sh` + `quality-gate.sh` |
| **OD-4** | **A**: SM 用 `merge-main-into-pbi.sh` 新設 (PBI worktree に main を merge)、`safe-switch-to-main.sh` も新設。`pbi-merge/SKILL.md:61` の rebase 指示を新フローに書換 | `scripts/scrum/` に2本新規 + `pbi-merge/SKILL.md` + 関連test |
| **OD-5** | **OD-3 結果待ち**: `TaskCompleted` 発火しなければ `quality-gate.sh` を `SubagentStop` 配下へ rewire か退役 | OD-3 に従属 |
| **OD-6** | **A**: status ownership は doc-only convention であることを明記。machine guard は追加しない | `update-backlog-status.sh` 冒頭コメント + `scrum-master.md` / `developer.md` の 1行注記 |
| **OD-7** | **グラフ拡張**: `escalated → blocked → in_progress_design` を documented status graph に追加 | `CLAUDE.md` PBI status flow, `data-model.md` State Transitions, `scrum-master.md` |
| **OD-8** | **即削除**: `setup-user.sh:140-156` `legacy_dir` cleanup を削除 | `setup-user.sh` |

## Tier 1 — Real bugs (10 items)

| # | Where | 修正方針 | Depends on |
|---|---|---|---|
| **T1-1** | `hooks/completion-gate.sh:163-179` | `case` allow-list に `in_progress_merge` 追加 + line 179 のメッセージから `in_progress_merge` を allow-list に表示 | — |
| **T1-2** | `skills/pbi-merge/SKILL.md:61` | rebase 指示を「SM が `merge-main-into-pbi.sh <pbi-id>` 実行 → Developer が worktree で衝突解決 → `commit-pbi.sh` で commit → `mark-pbi-ready-to-merge.sh` 再実行」に書換 | OD-4 (新ラッパー2本) |
| **T1-3** | `hooks/stop-failure.sh:25-37` | event type を `status_transition` (already used at dashboard-event.sh:309) に統一、もしくは schema enum に `stop_failure` 追加。OD-2 で wrapper 経由化されると schema validation が走るので、enum に追加が安全 | OD-2 (validation enforcement) |
| **T1-4** | `hooks/dashboard-event.sh:438` | `sender_role: "system"` に変更 (external/file-watch セマンティクスと一致) | OD-2 |
| **T1-5** | `tests/dashboard/test_app.py:31,215,268,281,309` | `PBIProgressBoard` → `UnifiedPbiBoard` に rename。assertions も `unified_pbi_board` に同期 | — |
| **T1-6** | `tests/dashboard/test_app.py:97` | assertion を `"pbi_pipeline_active"` に修正 (fixture が既に `pbi_pipeline_active`) | T1-5 と同 PR |
| **T1-7** | `tests/dashboard/test_app.py:52,57` | `format_phase("implementation")` → `format_phase("pbi_pipeline_active")` | T1-5 と同 PR |
| **T1-8** | `dashboard/app.py:153-154` | `PHASE_FLOW` から `("design", "Design")` と `("implementation", "Implementation")` 2行削除。`migrate-legacy.sh:205-206` で remap 済み | T1-5 と同 PR |
| **T1-9** | `tests/integration/test_pbi_pipeline_happy_path.bats:33` | `"sprint_id"` → `"id"` に rename | T1-10 と同 PR |
| **T1-10** | `tests/integration/test_pbi_pipeline_happy_path.bats:37` | `"assigned_pbis": [...]` → `"assigned_work": {"implement": [...]}` に書換 | T1-9 と同 PR |

## Tier 2 — Drift

### T2a Wiring gaps (3)

| # | Issue | 方針 |
|---|---|---|
| **T2a-1** | `state.json.active_pbi_pipelines[]` writer 不在 | OD-1 で **削除側に振る**。schema, hook 読込, state-management.md, data-model.md から撤去 |
| **T2a-2** | `init-pbi-state.sh` ラッパー不在 (state-management.md:55-66 が raw `jq -n >` 指示、guard hook がブロック) | 新ラッパー `scripts/scrum/init-pbi-state.sh <pbi-id>` を新設。`state-management.md:55-66` をラッパー呼び出しに書換 |
| **T2a-3** | `append-{dashboard-event,communication}.sh` の caller 不在 | OD-2 (= T1-3, T1-4 と同 PR) で hooks をラッパー経由化することで解消 |

### T2b Schema drift (9)

| # | Where | 修正方針 |
|---|---|---|
| **T2b-1** | `backlog.schema.json:43` `size` field 完全 dead | schema から `size` を削除 (未使用 enum) |
| **T2b-2** | `data-model.md:64-86` PBI table | `merged_sha` / `merged_at` 行を追加 |
| **T2b-3** | `data-model.md:432` DashboardEvent type enum | `test_run`, `review_verdict` を追加 |
| **T2b-4** | `data-model.md:427-438` DashboardEvent table | `status_from`, `status_to` 行を追加 |
| **T2b-5** | `docs/contracts/scrum-state/README.md:5-12` writer table | 7 wrapper を全て列挙する形に書換 (`create-pbi-worktree.sh`, `commit-pbi.sh`, `mark-pbi-ready-to-merge.sh`, `mark-pbi-merged.sh`, `mark-pbi-merge-failure.sh`, `freeze-sprint-base.sh`, `init-pbi-state.sh` (T2a-2)) |
| **T2b-6** | `state.active_pbi_pipelines[]` ↔ `sprint.developers[].current_pbi` dual-SSOT | OD-1 で `active_pbi_pipelines` 削除 → `current_pbi` のみ残し解消 |
| **T2b-7** | `CLAUDE.md:88` sprint flow | `\| failed` を terminal に追記 |
| **T2b-8** | `.scrum/config.json` schema 不在 | (a) `Config` entity を `data-model.md` に追加、または (b) `.scrum-config.example.json` を de-facto contract と注記。**推奨 (b)** (1ファイルしかない/設定としては小さい) |
| **T2b-9** | `dashboard.schema.json:33` `change_type` loose | schema を enum (`created\|modified\|deleted`) に締める |

### T2c Doc-claim drift (8)

| # | Where | 修正方針 |
|---|---|---|
| **T2c-1** | `pbi-merge/SKILL.md:37` precondition | "porcelain empty" → "tracked changes 無し (untracked OK — `.scrum/` は untracked のため許容)" |
| **T2c-2** | `update-backlog-status.sh` actor enforcement | OD-6: ラッパー冒頭に「ownership は doc-only convention」と注記、actor enforcement は実装しない旨明記 |
| **T2c-3** | `pbi-escalation-handler` の `escalated → blocked → in_progress_design` | OD-7: documented status graph に追記 |
| **T2c-4** | `pbi-merge/SKILL.md:23-25` 失敗リトライ narrative | "リトライ中も status は `in_progress_merge` のまま、`mark-pbi-ready-to-merge.sh` 再実行で `head_sha`/`ready_at`/`paths_touched` が再スタンプされる" を明記 |
| **T2c-5** | `pbi-pipeline/SKILL.md` Outputs + `developer.md` Strict Rules | "raw `git commit` は `.scrum` symlink を merge に漏らす — `commit-pbi.sh` のみが安全" を1行追加 |
| **T2c-6** | `install-subagents/SKILL.md:21` `10` | `11` に修正 |
| **T2c-7** | `pbi-pipeline/SKILL.md:18` "6 sub-agents verified by install-subagents" | "6 PBI Pipeline sub-agents (subset of the 11 verified by install-subagents)" に書換 |
| **T2c-8** | `mark-pbi-merged.sh:34-35` (out-of-scope obs) | success 時に `merge_failure = null` も clear する追加処理 |

### T2d Stale refs (already catalogued + 4 missed)

stale-refs.md に記録済み 11件:
- `tests/dashboard/test_app.py:{31,52,57,97,215,268,281,309}` — T1-5/6/7 で潰す
- `dashboard/app.py:153-154` — T1-8 で潰す
- `tests/integration/test_pbi_pipeline_happy_path.bats:{33,37}` — T1-9/10 で潰す
- `docs/MIGRATION-scrum-state-tools.md:18` — `update-state-phase.sh design` 例 → `pbi_pipeline_active` に置換
- `docs/MIGRATION-scrum-state-tools.md:83` — `update_pbi_pipelines` 言及削除 (T2d-15 と同箇所)
- `README.md:74` + `scripts/setup-user.sh:422` — `codex-code-reviewer` 言及を 5-aspect reviewer モデルに書換 (T3-C9 と同 PR)
- `docs/superpowers/plans/2026-05-06-cleanup-audit.md:78` — T1-7 行に `[obsolete: function removed in e93c729]` 注記

NEW (4件):
- **T2d-12** "14 ceremony skills" → "15" + `pbi-merge` 追加: `README.md:58,157`, `agent-interfaces.md:19,90`, `architecture.md:212-228`
- **T2d-13** README peer-review prose: `README.md:51,106` を 5-aspect reviewer モデル記述に置換
- **T2d-14** `agent-interfaces.md` Skills Mapping (70-85) + Skill IO Reference (92-107) に `pbi-merge` 行追加
- **T2d-15** `MIGRATION-scrum-state-tools.md:83` 第二の `update_pbi_pipelines` 言及削除

## Tier 3 — Markdown redundancy (12 clusters)

PR バッチ:

- **PR-T3-1 (sub-agents catalog)** — C1 + C2 + C6/T2d-12 + C10/T2d-14: canonical = `docs/contracts/sub-agents.md`
- **PR-T3-2 (data-model status)** — C3: canonical = `docs/data-model.md § State Transitions: status`
- **PR-T3-3 (setup boilerplate)** — C4 + C5 + C7: canonical = `docs/quickstart.md` + `CLAUDE.md`
- **PR-T3-4 (requirements internal)** — C12: AS1/AS4/Q&A の 5-reviewer 列挙を US5/FR-009 へ縮約
- **PR-T3-5 (peer-review prose)** — C9/T2d-13: README:51,106
- **PR-T3-6 (lifecycle)** — C11: README ASCII vs 形式flow を整合 or "marketing summary" として明示

C8 (`install-subagents:21` の 10/11) は T2c-6 で吸収。

## Tier 4 — Code redundancy

- **T4-1** = T1-3/T1-4/OD-2 の副産物 (hook → wrapper シェルアウトで自動消滅)
- **T4-2** `get_pbi_status` duplication (acknowledged-intentional, low) — **保留**
- **T4-3** `get_timestamp` / `_iso_utc_now` duplication (acknowledged-intentional, low) — **保留**
- **T4-4** `block()` helper 2重定義 → `hooks/lib/validate.sh` に `hook_block(hook, msg, remediation)` 抽出
- **T4-5** `ensure_comms_file` / `append_comms_message` inline copy → `hooks/lib/dashboard.sh` (or rename `lib/jsonlog.sh`) に統合 — **OD-2 実装で同時消化**
- **T4-6** `migrate-legacy.sh:75-114, 169-194` sprint-migration block が `apply_migration` の literal copy → `apply_migration_with_args` に統一
- **T4-7** `quality-gate.sh:19-25` warn/info wrapper — OD-3/OD-5 の判断後に対応
- **T4-8** `hooks/dashboard-event.sh:453-484` PostToolUse default branch 不到達 → 削除
- **T4-9** `setup-user.sh:140-156` legacy_dir cleanup → OD-8 で削除
- **T4-10** `is_duplicate_comms` mis-named → `is_immediate_duplicate_comms` に rename (low)

## Tier 5 — Cosmetic

- **T5-1** `hooks/lib/codex-invoke.sh` mis-located → `scripts/lib/codex-invoke.sh` に移動 + 3 codex agent docs + setup-user.sh + tests/unit/test_codex_invoke.bats + architecture.md:495 を更新 (deferred from previous round)
- **T5-2** `hooks/completion-gate.sh:179` block message 用語 ("PBI Pipeline phase" → "Project phase 'pbi_pipeline_active'") — T1-1 と同 PR
- **T5-3** `MIGRATION-scrum-state-tools.md:101-115` v1 narrative — Appendix 化 or 削除を判断 (機会主義的)

## 実行順序 (PR バッチ)

| 順 | PR | 内容 | 依存 |
|---|---|---|---|
| 1 | **PR-OD3** | OD-3 スモークテスト (一時スクリプトで 5 イベント発火確認) → 結果を本planに追記 | — |
| 2 | **PR-OD4** | `merge-main-into-pbi.sh` + `safe-switch-to-main.sh` 新設 + tests | — |
| 3 | **PR-OD2** | hooks → SSOT wrapper シェルアウト (T1-3, T1-4, T2a-3, T4-1, T4-5 同梱) | OD-3 結果次第で event type 確定 |
| 4 | **PR-OD1** | `active_pbi_pipelines[]` 削除 (T2a-1, T2b-6 同梱) | — |
| 5 | **PR-T1-A** | `completion-gate.sh` allow-list (T1-1, T5-2) | — |
| 6 | **PR-T1-B** | `pbi-merge/SKILL.md` 新フロー記述 (T1-2, T2c-1, T2c-4) | PR-OD4 |
| 7 | **PR-T1-C** | dashboard test + PHASE_FLOW (T1-5, T1-6, T1-7, T1-8) | — |
| 8 | **PR-T1-D** | bats fixture (T1-9, T1-10) | — |
| 9 | **PR-T2a-2** | `init-pbi-state.sh` ラッパー新設 (T2a-2) + state-management.md 書換 | — |
| 10 | **PR-T2d** | stale refs 14件一括 (記録済 + 4 missed) | PR-T3-1 と前後 |
| 11 | **PR-T2b** | schema/doc 同期 (T2b-1〜T2b-9 / 必要分は OD batch で済) | — |
| 12 | **PR-T2c** | doc-claim drift (T2c-2/3/5/6/7/8) | OD-6, OD-7 |
| 13 | **PR-T3-1〜PR-T3-6** | markdown 冗長 6PR | T2d 並走可 |
| 14 | **PR-T4-A** | dead-code 削除 (T4-8, T4-9 = OD-8) | — |
| 15 | **PR-T4-B** | `block()` 抽出 (T4-4) | — |
| 16 | **PR-T4-C** | `migrate-legacy.sh` dedupe (T4-6) | — |
| 17 | **PR-T5-1** | `codex-invoke.sh` 移動 (deferred → 復活) | — |
| 18 | **PR-OD5/T4-7** | OD-5/T4-7 (`quality-gate.sh` 処遇) | OD-3 結果 |

各 PR 完了時に下記 "Done log" を更新する。

## Done log

| PR | Date | Commit | Verdict | Notes |
|---|---|---|---|---|
| **PR-T1-A** | 2026-05-07 | `49ef7e6` | ✅ | `completion-gate.sh` allow-list に `in_progress_merge` 追加。block message を "Project phase 'pbi_pipeline_active'" 表現に統一。テスト追加。 |
| **PR-T1-D** | 2026-05-07 | `04b15e3` | ✅ | bats integration fixture を `id`/`assigned_work.implement`/`started_at`/`status` に同期。|
| **PR-T1-C** | 2026-05-07 | `c858934` | ✅ | `PHASE_FLOW` から `design`/`implementation` 行削除。`PBIProgressBoard`→`UnifiedPbiBoard` rename + 失われた `_pbi_sort_key` import 削除 + 死んだ `TestPipelineHelpers` 削除（plan 範囲外だが import 失敗で test collection 不可だった）。30 dashboard tests pass。 |
| **PR-OD1** | 2026-05-07 | `932ee8f` | ✅ | `state.json.active_pbi_pipelines[]` を schema/hook 両方から削除。`completion-gate.sh` と `session-context.sh` を `backlog.json` 由来 (`select(.status \| startswith("in_progress_"))`) に切替。data-model.md / state-management.md / MIGRATION docs 同期。T2a-1 / T2b-6 / T2d-15 / 旧 `update-state-phase.sh design` 例 (T2d-stale) 一括解消。|
| **PR-T4-A** | 2026-05-07 | `ad5e068` | ✅ | `dashboard-event.sh` 末尾 `*)` default + `setup-user.sh` legacy_dir cleanup 削除 (T4-8, T4-9 / OD-8)。|
| **PR-T2a-2** | 2026-05-07 | `183eee0` | ✅ | `init-pbi-state.sh` ラッパー新設 (idempotent, schema 検証込み)。state-management.md / scrum-state README 同期。4 unit tests 追加。|
| **PR-OD4**   | 2026-05-07 | `809f1e1` | ✅ | `merge-main-into-pbi.sh` + `safe-switch-to-main.sh` 新設 (sandbox: bash → git -C worktree merge --no-ff main)。setup-user.sh は既存 glob で deploy。14 unit tests (happy / no-op / conflict / rejection 全パス)。|
| **PR-T1-B**  | 2026-05-07 | `1a71046` | ✅ | `pbi-merge/SKILL.md` の rebase 指示を `merge-main-into-pbi.sh` フローに書換。T2c-1 (precondition: tracked changes 無し / `.scrum/` untracked OK) と T2c-4 (リトライ中も `in_progress_merge`、`mark-pbi-ready-to-merge.sh` 再実行で `head_sha`/`paths_touched`/`ready_at` 再スタンプ) 同梱。|
| **PR-T2d**   | 2026-05-07 | `151c57d` | ✅ | T2d-12 (skill count 14→15: pbi-merge を README:58/157, agent-interfaces.md:19/90, architecture.md skill tree に追加)、T2d-13/T3-5 (peer-review prose: README:51/106/149)、T2d-14 (Skills Mapping + Skill IO Reference に pbi-merge 行追加)、T2d-stale (`codex-code-reviewer` → 5-aspect reviewer 表現に: README:74, setup-user.sh:404)、T2d-misc (旧 plan 2026-05-06:78 に obsolete 注記)。|
| **PR-T2b**   | 2026-05-07 | `d0f1a51` | ✅ | T2b-1 (backlog `size` enum 削除)、T2b-2 (data-model PBI table に `merged_sha`/`merged_at` 行追加)、T2b-3/T2b-4 (DashboardEvent type enum に `tool_use`/`test_run`/`review_verdict` + `status_from`/`status_to` 行追加)、T2b-5 (scrum-state README writer table を 7 wrapper 全列挙に書換)、T2b-7 (CLAUDE.md sprint flow に `\| failed` terminal 追加)、T2b-8 (Config entity を data-model.md に追加: `.scrum-config.example.json` を de-facto contract と注記)、T2b-9 (dashboard.schema `change_type` を `enum(created\|modified\|deleted\|null)` に締める + テスト fixture 修正 + 拒否テスト追加)。|
| **PR-T2c**   | 2026-05-07 | `6636049` | ✅ | T2c-2 (update-backlog-status.sh に actor ownership は doc-only convention 注記)、T2c-3 (CLAUDE.md SM-managed flow に `escalated → in_progress_design` / `escalated → blocked → in_progress_design` 明示)、T2c-5 (pbi-pipeline/SKILL.md Outputs + developer.md Strict Rules: `commit-pbi.sh` のみが安全 (`.scrum` symlink 除外))、T2c-6 (install-subagents 10→11)、T2c-7 (pbi-pipeline 6 sub-agent を "subset of 11" 表現に)、T2c-8 (`mark-pbi-merged.sh` で success 時に `del(.merge_failure)` + 回帰テスト)。|
| **PR-T4-B**  | 2026-05-07 | `538106d` | ✅ | hooks の重複 `block()` を `hooks/lib/validate.sh::hook_block(hook,what,remediation)` に集約。各 hook は 1-line wrapper で call site 互換維持。|
| **PR-T4-C**  | 2026-05-07 | `e381a84` | ✅ | `migrate-legacy.sh` sprint-migration block (26行 literal copy) を `apply_migration_with_args` に統合。`apply_migration` を thin wrapper に格下げ。|
| **PR-T5-1**  | 2026-05-07 | `a553868` | ✅ | `hooks/lib/codex-invoke.sh` → `scripts/lib/codex-invoke.sh` (codex-* reviewer agents 用 helper であり hook 用ではない)。call site 更新: codex-design-reviewer.md, test_codex_invoke.bats, test_pbi_pipeline_happy_path.bats (setup() で `scripts/lib/` も copy), architecture.md。setup-user.sh は `scripts/lib/*.sh` → `<target>/scripts/lib/` を deploy。|
| **PR-T3-2**  | 2026-05-07 | `66a2f1f` | ✅ | requirements.md Q&A と scrum-master.md Workflow に重複していた 12-value PBI status 列挙を `docs/data-model.md § State Transitions` への canonical reference に縮約 (CLAUDE.md は always-loaded primer なので summary 維持)。|
| **PR-T3-4**  | 2026-05-07 | `c20f538` | ✅ | requirements.md AS1 + cross-review Q&A の 5-reviewer 列挙 → US5 への参照に縮約。|

### このセッションで未着手の PR

- **OD-3 / OD-2 / OD-5 / T4-7** (runtime 検証必須): 実 Claude Code harness で `SubagentStart`/`TaskCompleted`/`TeammateIdle`/`FileChanged`/`Agent` matcher が発火するか smoke 検証 → 結果次第で hooks の SSOT-wrapper 経由化 (OD-2) と `quality-gate.sh` の処遇 (OD-5/T4-7) を確定。
- **PR-T3-1 / PR-T3-3 / PR-T3-6** (markdown 冗長 残り): sub-agents catalog clusters (C1+C2+C6+C10), setup boilerplate (C4+C5+C7), README lifecycle ASCII vs 形式 flow 整合 (C11)。低 ROI のため独立 PR として deferral。

**注:** stop-failure.sh の event type 修正 (T1-3) と `dashboard-event.sh` の `sender_role: "system"` (T1-4) は OD-2 batch に同梱予定 (= 未着手)。

## Verification

各 PR 完了時に以下を実行:

- `bats tests/unit/ tests/lint/` (and `tests/integration/` for state-touching PRs)
- `shellcheck scrum-start.sh scripts/*.sh scripts/lib/*.sh hooks/*.sh hooks/lib/*.sh`
- `ruff check dashboard/ && ruff format --check dashboard/`
- 必要に応じて `pytest tests/dashboard/` (T1-C 完了後は通る前提)

最終 PR 完了時の総合検証:
- 全 stale refs スキャン (`grep -rn pbi_pipelines\|PBIProgressBoard\|sprint_id\|assigned_pbis\|design\|implementation` で意図しない hit が無いこと)
- `git diff main..HEAD --stat` で全変更の overview レビュー
