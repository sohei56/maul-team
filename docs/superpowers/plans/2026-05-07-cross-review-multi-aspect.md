# Cross Review Multi-Aspect Refactor — Work Plan

**Date:** 2026-05-07
**Branch:** `refactor/status-phase-unification`（同ブランチ継続。新規切る場合は `refactor/cross-review-multi-aspect`）
**Status:** Plan only — 着手前

## Background

現状の `cross-review` skill は PBI ごとに 2 体（`codex-code-reviewer` + `security-reviewer`）並列起動。観点が混在しており、要件適合性 / 機能品質（境界値・エラー制御） / 保守性 / ドキュメント品質 が独立に評価されない。SM が観点別エージェントを起動して多角化したい、というユーザー要望。

並列して走る per-PBI Round の `codex-impl-reviewer` / `codex-ut-reviewer`（pbi-pipeline 専用）とは別系統。`codex-code-reviewer` は cross-review からのみ参照されており、置き換え対象。

## Goals

1. cross-review を 5 観点 × 1 体 = **5 体並列**（PBI 単位 fan-out なし、Sprint 全体一括）に再設計
2. FAIL 振り分けを観点別に分離（観点 1/2/3 → `in_progress_impl` 戻し / 観点 4/5 → 次 Sprint 解消 PBI 化）
3. デッドコード判定は静的解析併用（LLM 単独不可）
4. 重複 follow-up PBI 生成を防止（idempotent）

## Design decisions（確定）

| 項目 | 決定 |
|---|---|
| 観点 1 要件適合性 | 新 agent `requirement-conformance-reviewer` |
| 観点 2 機能品質 | 新 agent `functional-quality-reviewer`（**cross-PBI 限定**：PBI 間 I/F の境界値・エラー伝播・状態遷移） |
| 観点 3 セキュリティ | 既存 `security-reviewer` 流用（変更なし） |
| 観点 4 保守性 | 新 agent `maintainability-reviewer`（**静的解析を Bash で事前実行 → LLM が結果を入力に取る**） |
| 観点 5 ドキュメント品質 | 新 agent `docs-consistency-reviewer`（Receives = `docs/**` + 実装 file 一覧 diff） |
| 並列度 | 観点ごと 5 並列、PBI 単位 fan-out なし。各 reviewer は Sprint 全 PBI を一括レビュー |
| 実行回数 | 全マージ後 1 回（FAIL ループ時は **全観点再実行**） |
| Severity 閾値 | Critical/High のみ FAIL 扱い（既存仕様踏襲） |
| 観点 1/2/3 FAIL | 該当 PBI を `cross_review → in_progress_impl` に戻し |
| 観点 4/5 FAIL | 該当 PBI は通過、別 PBI を `add-backlog-item.sh` で次 Sprint 用に追加 |
| follow-up PBI dedup | title prefix `[cross-review-followup:<pbi-id>:<aspect>]` で既存検索 → あればスキップ |
| 旧 agent 処遇 | `codex-code-reviewer` / `code-reviewer` 削除 |

## Reference

- 現行 cross-review: `skills/cross-review/SKILL.md`
- 既存 reviewer: `agents/security-reviewer.md`（流用）、`agents/codex-code-reviewer.md` / `agents/code-reviewer.md`（削除対象）
- per-PBI 系（**触らない**）: `agents/codex-impl-reviewer.md`、`agents/codex-ut-reviewer.md`、`agents/codex-design-reviewer.md`
- 新 PBI 追加スクリプト: `scripts/scrum/add-backlog-item.sh`（既存利用可）
- 状態 schema: `docs/contracts/scrum-state/backlog.schema.json`

## Tasks

### T1. 新 agent 定義の作成（4 本）

T1-1. `agents/requirement-conformance-reviewer.md`
- Receives: `requirements.md` / `docs/design/specs/**` / Sprint 全 PBI source paths（`backlog.json items[].paths_touched`）
- 観点: 要件網羅・スコープ逸脱・design spec との乖離
- Findings 形式: `<file_path>:<line>:<criterion>` + **PBI mapping** （`paths_touched` から逆引き）
- 出力 verdict: PASS / FAIL（PBI 単位ではなく観点単位の verdict、ただし Findings には PBI id を必ず含める）

T1-2. `agents/functional-quality-reviewer.md`
- Receives: 同上 + 「**PBI 間 I/F に限定**」明記
- 観点: 境界値・異常系・状態遷移・PBI 間のエラー伝播・データ整合
- 「PBI 単体の境界値は UT 担当のため対象外」を Strict Rules に明記
- Findings: 影響する複数 PBI を列挙

T1-3. `agents/maintainability-reviewer.md`
- Receives: source paths + **静的解析結果ファイル**（`.scrum/reviews/static-analysis-r{n}.json`）
- 観点: 過抽象・重複・凝集度・神クラス・神関数・**デッドコード（静的解析結果が一次根拠）**
- Strict Rules: デッドコード判定は静的解析が指摘していない箇所を新規に主張しない（誤検出抑止）

T1-4. `agents/docs-consistency-reviewer.md`
- Receives: `docs/**` + `git diff --name-only sprint.base_sha..HEAD` の実装ファイル一覧
- 観点: doc-impl 乖離・古い記述・冗長構成
- Strict Rules: コード品質には立ち入らない（観点 4 と分離）

### T2. 旧 agent 削除

T2-1. `agents/codex-code-reviewer.md` 削除
T2-2. `agents/code-reviewer.md` 削除
T2-3. `skills/install-subagents/SKILL.md` の agent 列挙を更新（旧 2 体除外、新 4 体追加）

### T3. cross-review skill 改修

`skills/cross-review/SKILL.md` を全面書き換え。

T3-1. **Steps の差し替え**
- Step 5: 5 体並列起動（PBI 単位 fan-out なし、Sprint 全 PBI を一括レビュー）
- Step 4.5（新規）: 静的解析の事前実行
  - 言語別ツール選定: Python `ruff check --select F401,F841,ARG,B`、Shell `shellcheck`、Bash「未使用変数 / 未使用関数」抽出（grep ベース fallback OK）
  - 結果を `.scrum/reviews/static-analysis-r{n}.json` に集約
  - `maintainability-reviewer` の入力に渡す
- Step 8（FAIL handling）の差し替え:
  - 観点 1/2/3 FAIL Findings → 該当 PBI 列挙 → `update-backlog-status.sh "$PBI_ID" in_progress_impl`
  - 観点 4/5 FAIL Findings → 該当 PBI ごとに follow-up PBI を `add-backlog-item.sh` で追加（title prefix `[cross-review-followup:<pbi-id>:<aspect>]`、既存検索で dedup）
- Step 8 の再ループ: 観点 1/2/3 FAIL があれば全 5 体を再起動（観点別 partial 再実行はしない）

T3-2. **review doc 構造の決定**
- 観点別 doc: `.scrum/reviews/aspect-<aspect>-review.md`（5 ファイル）— 各 reviewer の生出力
- PBI 別 doc: `.scrum/reviews/<pbi-id>-review.md`（既存 schema 維持） — 5 観点の Findings を当該 PBI にフィルタして集約
- `items[].review_doc_path` は PBI 別 doc を指す（schema 変更なし）

T3-3. **重複 follow-up PBI 防止ロジック**
- `add-backlog-item.sh` 呼び出し前に `jq` で既存 backlog から title prefix 一致を検索
- 既存ありならスキップ、ログのみ出力

T3-4. **Inputs / Outputs / Preconditions / Exit Criteria** を新設計に同期

### T4. 周辺ドキュメント更新

T4-1. `agents/scrum-master.md`
- L56 FR-009 文言を新観点群に更新（5 reviewer 列挙 / 観点別 FAIL 振り分け説明）
- L121 workflow 行を更新

T4-2. `docs/contracts/agent-interfaces.md`
- L54 FR-009 行を更新
- L101 cross-review row（Inputs/Outputs）を更新（aspect-*.md 追加 / static-analysis.json 追加）

T4-3. `docs/quickstart.md` に cross-review 言及あれば追従更新（要 grep 確認）

### T5. テスト / Lint

T5-1. `bats tests/unit/ tests/lint/` 実行
T5-2. `shellcheck` cross-review 関連スクリプトに変更が及んだ場合のみ実行
T5-3. `markdownlint`（あれば）— skill / agent .md 群

### T6. CLAUDE.md / project memory 更新（必要に応じて）

T6-1. CLAUDE.md の cross-review 言及（あれば）を更新
T6-2. `project_status_phase_unification.md` memory に cross-review 多角化の影響メモ（観点別 follow-up PBI が backlog に追加される運用変化）

## Open Questions（着手中に判断 / ユーザー再確認候補）

OQ-1. 静的解析の言語選定：本リポは Bash + Python（dashboard）+ Markdown が主。target project では言語不定。**target project 側に `.scrum/config.json` で declared な言語ごとに静的解析コマンドを登録できる**仕組みが必要か？ MVP は `ruff` + `shellcheck` ハードコード、target 側カスタマイズは別 PBI に切り出す案を推奨。

OQ-2. follow-up PBI の `parent` フィールド：既存 PBI の id を `--parent` で渡すか？ 観点 4/5 の指摘元 PBI を辿れる利点あり。推奨：渡す。

OQ-3. Findings → PBI mapping の信頼性：`paths_touched` は PBI 単位の touched ファイル一覧。複数 PBI で同じファイルが touched された場合、Findings の file 行から PBI を一意に特定できない。
- 案 A: 該当する全 PBI に Finding を記載（多重カウント許容）
- 案 B: 最後に touched した PBI 1 つに紐付け（git blame ベース）
- 推奨：A（防止安全側）

OQ-4. 観点 4 の静的解析失敗時挙動：tool が exit non-zero で死んだ場合、`maintainability-reviewer` を skip するか LLM のみで動かすか？ 推奨：LLM のみ + warning ログ（PASS/FAIL 出力に「静的解析未実行」を明記）。

## Verification

- [ ] `bats tests/unit/ tests/lint/` 全 PASS
- [ ] `shellcheck` 関連スクリプト clean
- [ ] cross-review skill 内 `update-backlog-status.sh` / `add-backlog-item.sh` 呼び出しが integration test fixture 上で動作
- [ ] 旧 agent 削除後、`grep -rn "codex-code-reviewer\|code-reviewer" agents/ skills/ docs/ CLAUDE.md` が空（参照断ち確認）
- [ ] 新 agent 4 本が `install-subagents/SKILL.md` 列挙に含まれる
- [ ] cross-review FAIL ループの dedup ロジックが目視で正しい（同 PBI/aspect 二重追加されない jq クエリ確認）

## Out of scope

- per-PBI pipeline reviewer（`codex-impl-reviewer` / `codex-ut-reviewer` / `codex-design-reviewer`）の変更
- target project ごとの静的解析カスタマイズ機構（OQ-1 案で別 PBI 化）
- review doc schema の構造変更（`items[].review_doc_path` は文字列 1 本のまま維持）

## Build sequence

1. T1 新 agent 4 本を先に書く（独立、並列実装可）
2. T3 skill 改修（T1 完了後）
3. T2 旧 agent 削除（T3 完了後 — 削除前に新 skill が動くこと確認）
4. T4 ドキュメント追従（T2 と並列可）
5. T5 テスト / Lint
6. T6 memory / CLAUDE.md
