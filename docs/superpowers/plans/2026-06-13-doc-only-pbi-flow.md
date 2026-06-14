# Doc-only PBI Flow — Work Plan

**Date:** 2026-06-13
**Branch:** TBD（候補: `feat/doc-only-pbi-flow`）
**Status:** Plan only — 着手前

## Background

target project では doc-only PBI（修正対象が `.md` のみ）が cross-review follow-up を中心に多発しているが、`pbi-pipeline` は全 PBI に対し `Design → Impl ‖ UT → Review ‖ Review → UT Run+Coverage` を無条件で回す。結果として:

- AC を `grep -E '...' design.md が N 行返す` のような表面パターン検査で穴埋めし、UT author が grep を test 関数で wrap するだけの**空虚な UT** が生成される（target の pbi-054 が代表例）
- 一部の PBI（target の pbi-036）では PO/SM が苦肉の策として `scripts/verify_<pbi-id>_docs.py` を AC で要求 — 各 PBI ごとに別の workaround を発明しており、フレームワーク側で構造化されていない
- target で 10 件以上発生済み（pbi-036〜054 範囲に集中）→ 一時的異常ではなく構造的欠陥

## Goals

1. doc-only PBI を pipeline 段階で識別し、**Design + UT 系の作業を全撤廃**する
2. 必要な検証はクロスレビューの観点限定実施に集約（aspect 1 + aspect 5 のみ）
3. AC 品質ゲートを refinement に追加し、grep 型表面 AC を撲滅する
4. doc-only 自称 PBI が実装に触れる事故を `mark-pbi-ready-to-merge.sh` で machine-enforce

## Design decisions（確定）

| 項目 | 決定 |
|---|---|
| 機械判定基準 | `paths_touched` 全要素が `*.md` パターンにマッチ → kind=docs |
| 境界カバレッジ | `docs/**/*.md` / `skills/**/*.md` / `agents/**/*.md` / `CLAUDE.md` / `README.md` 全て include（`.md` 一発 glob で判定） |
| kind 確定タイミング | refinement の AC audit 時に `backlog.json` へ永続化（Sprint Planning から可視） |
| Design Stage | kind=docs では **完全スキップ**（pbi-designer 不要、design.md 生成しない）。implementer 直行 |
| Impl Stage | kind=docs では pbi-implementer のみ spawn。pbi-ut-author は spawn しない |
| PBI Review Stage | kind=docs では codex-impl-reviewer のみ（docs 観点で review）。codex-ut-reviewer は spawn しない |
| UT Run Stage | kind=docs では **完全スキップ**。coverage_status / ut_status は `skipped` |
| ready-to-merge 境界 enforce | `mark-pbi-ready-to-merge.sh` が `paths_touched ⊆ **/*.md` を強制 check。違反 → `escalated(kind_mismatch)` |
| Cross-review aspect filter | kind=docs PBI は aspect 1 (req-conformance) + aspect 5 (docs-consistency) のみで評価。aspect 2/3/4 の対象から除外 |
| Cross-review reviewer spawn | Sprint 全 PBI が kind=docs なら aspect 2/3/4 reviewer は spawn しない（無対象） |
| AC 品質 (refinement) | kind=docs PBI で `grep ... が N 行返す` 型 AC は禁止。Given/When/Then または意味的に検証可能な形を要求 |
| follow-up 無限ループ防止 | doc-only PBI に対する docs-consistency follow-up が連続 2 回出たら escalation（人手判断へ） |
| 既存 backlog migration | 全 PBI に `kind="code"` を埋める one-shot script を提供 |

## Non-goals

- 「設計書のドキュメント PBI」と「README 修正 PBI」を細分化することは目的外（どちらも kind=docs で十分）
- markdown-link-check 等のツール追加導入は今回スコープ外（aspect 5 reviewer の質改善は別計画）
- pbi-036 のような「`verify_*_docs.py` を AC に書く」既存 workaround の遡及修正は対象外（migration 時は既存通り `kind="code"` 扱いでよい — 過去の done PBI を再評価しない）

## Reference

- 現行 pipeline: `skills/pbi-pipeline/SKILL.md`, `skills/pbi-pipeline/references/impl-ut-stage.md`
- 現行 cross-review: `skills/cross-review/SKILL.md`
- 状態 schema: `docs/contracts/scrum-state/backlog.schema.json`, `docs/contracts/scrum-state/pbi-state.schema.json`
- refinement: `skills/backlog-refinement/SKILL.md`（AC audit 内に既に `docs-only` 種別識別ロジックあり、L70-72）
- backlog wrapper: `scripts/scrum/add-backlog-item.sh`
- ready-to-merge wrapper: `scripts/scrum/mark-pbi-ready-to-merge.sh`
- 実例: target project pbi-054（doc-only かつ grep 型 UT）, pbi-036（doc-only かつ verify script workaround）

## Tasks

### T1. Schema 拡張

**T1-1.** `docs/contracts/scrum-state/backlog.schema.json` に `kind` 追加
- `"kind": { "enum": ["code", "docs"], "default": "code" }`
- `additionalProperties: false` のため、追加必須
- migration 対応: 既存データは `default: "code"` で読まれるが、永続化時には埋める

**T1-2.** `docs/contracts/scrum-state/pbi-state.schema.json` に `skipped` enum 追加
- `design_status`, `ut_status`, `coverage_status` の enum に `"skipped"` を追加
- description に「skipped: kind=docs PBI で当該 stage を実行しなかった」追記

**T1-3.** `tests/fixtures/scrum-state/` に kind=docs / skipped 状態のフィクスチャ追加

### T2. Wrapper script 改修

**T2-1.** `scripts/scrum/add-backlog-item.sh` に `--kind {code,docs}` フラグ追加
- 未指定時 `code`（default）
- 値 validation（code|docs 以外は error）

**T2-2.** `scripts/scrum/mark-pbi-ready-to-merge.sh` に kind 境界 enforce 追加
- 対象 PBI の `backlog.json items[].kind` を読む
- `kind == "docs"` のとき、`paths_touched` 全要素が `*.md` パターンに一致するか check
  - 違反時: state.json に `escalation_reason = "kind_mismatch"` を書き、`backlog status = escalated` に遷移、rc=1 で exit
- `kind == "code"` のときは既存挙動を維持

**T2-3.** （optional）`scripts/scrum/set-backlog-item-field.sh` で `kind` を後から修正可能にする（refinement 内で grep 型 AC を発見した場合の救済用）

### T3. backlog-refinement skill 改修

**T3-1.** `skills/backlog-refinement/SKILL.md` の AC audit プロンプトに kind 判定ロジックを明文化
- 既に L70-72 で `docs-only` 種別判定はあるので、それを永続化対象に追加
- 判定根拠: description 内のキーワード + AC が doc 操作系のみ + `catalog_targets ⊂ docs/**` のいずれか

**T3-2.** AC 品質ゲート追加（kind=docs 限定）
- grep 型 AC を Anti-pattern として明示
  - 禁止例: `"grep -E '...' file.md が N 行返す"`
  - 推奨例: `"file.md の §X に <意味的内容> が記載されている（reviewer による読解で判定）"`
- AC audit 内で grep 型 AC を検出 → verdict=needs_revision

**T3-3.** kind の永続化: `add-backlog-item.sh --kind docs` 呼び出しで反映

### T4. pbi-pipeline skill 改修

**T4-1.** `skills/pbi-pipeline/SKILL.md` 改訂
- Stages 図に kind 分岐を明記
- kind=docs PBI のフロー図を別途追加
- Init 時の status 遷移: kind=docs では `in_progress_design` を経由せず直接 `in_progress_impl` へ
- state.json 初期化時に `design_round=0, design_status=skipped` を書く

**T4-2.** `skills/pbi-pipeline/references/design-stage.md` に kind=docs スキップを明記
- 冒頭に「kind=docs では本 stage 全体をスキップ」セクション追加

**T4-3.** `skills/pbi-pipeline/references/impl-ut-stage.md` に kind 分岐を実装
- Step 1: kind=docs では pbi-implementer のみ spawn（parallel pair を解除）
- Step 2: kind=docs では codex-impl-reviewer のみ spawn
- Step 3 (UT Run): kind=docs ではスキップ → 直接 ready-to-merge handoff へ
- Step 4 (Pass criteria): kind=docs では coverage / AC coverage gate を skip
- 各 status 書き込みで `skipped` を使う

**T4-4.** `skills/pbi-pipeline/references/sub-agent-prompts.md` に kind=docs 用の codex-impl-reviewer 入力テンプレートを追加
- 入力: 親 PBI の `.scrum/reviews/<parent-pbi>-review.md` + 修正対象 .md ファイル + AC
- 評価軸: 「AC が意味的に充足されているか（grep ヒット数ではなく文章として）」「親 cross-review 指摘の解消」「cross-ref / frontmatter 整合」

**T4-5.** `skills/pbi-pipeline/references/coverage-gate.md` に kind=docs での skip 条件追記

**T4-6.** `skills/pbi-pipeline/references/termination-gates.md` に kind=docs 用ゲート定義
- design / ut round の hard cap は 0（そもそも回さない）
- impl round の hard cap は code と同じ 5

### T5. pbi-implementer agent 改修

**T5-1.** `agents/pbi-implementer.md` に kind=docs モード追加
- kind=docs 時の入力: design.md なし、代わりに親 PBI 関連 review + 修正対象 .md
- 出力: .md ファイル修正のみ。新規ファイル作成は `docs/`, `skills/`, `agents/` 配下 + ルート `*.md` に限定
- Strict Rule: 非 .md ファイルへの書き込み禁止（違反時 ready-to-merge で escalate される旨明記）

### T6. cross-review skill 改修

**T6-1.** `skills/cross-review/SKILL.md` の Step 8 に kind フィルタ追加
- Sprint PBI 分類: code PBIs と docs PBIs に分割
- aspect 1 (req-conformance): 全 PBI 対象（既存通り）
- aspect 2/3/4: code PBI のみ対象。Sprint に code PBI が 0 なら reviewer spawn しない
- aspect 5 (docs-consistency): 全 PBI 対象（既存通り）

**T6-2.** reviewer 入力の調整
- aspect 1 reviewer に「docs PBI の AC 検証は grep ヒット数ではなく内容の意味で判定」を Strict Rule で追記
- aspect 5 reviewer に「docs PBI の親 PBI の指摘解消」観点を追加

**T6-3.** follow-up 無限ループ防止
- `add-backlog-item.sh` 呼び出し前に「同一 ancestor chain で docs-consistency follow-up が連続 2 回出たか」check
- 該当時は follow-up 作成せず親 PBI を `escalated` にして人手判断へ送る

### T7. ドキュメント

**T7-1.** `CLAUDE.md` の PBI status flow セクションに kind 概念追加
- kind=docs PBI の状態遷移を明記（design → impl → review → merge、UT 系スキップ）
- `skipped` 状態が `*_status` の正規値である旨

**T7-2.** `docs/data-model.md` に `kind` フィールド説明追加
- `backlog.json items[].kind` の意味
- `pbi-state.json *_status` の `skipped` 値
- doc-only PBI の状態遷移図

**T7-3.** `docs/contracts/scrum-state/README.md`（あれば）に schema 変更履歴追記

### T8. Migration

**T8-1.** `scripts/scrum/migrate-add-kind-field.sh` 作成
- 既存 `.scrum/backlog.json` の全 items に `kind="code"` を埋める（idempotent）
- 過去の done PBI は触らない（status: done のままで kind="code" を埋めるだけ）
- target project に手動適用してもらう想定（フレームワーク repo 側では framework 自身の .scrum も対象）

**T8-2.** `MIGRATION-scrum-state-tools.md` に v2 → v3 として追記
- 追加フィールド: `kind`
- 後方互換: `default: "code"` で既存データは読める
- 既存 ut/ac-coverage で grep 型 tests を持つ PBI は migration 対象外（過去ログ保持）

## Tests

### Schema tests

- `tests/fixtures/scrum-state/backlog-kind-docs.json` でバリデーション pass
- `tests/fixtures/scrum-state/pbi-state-all-skipped.json` でバリデーション pass
- 不正値（`kind: "doc"` 単数形 / `*_status: "skip"`）が reject

### Unit tests (Bats)

- `tests/unit/add-backlog-item.bats`: `--kind docs` で `kind="docs"` 永続化
- `tests/unit/mark-pbi-ready-to-merge.bats`:
  - kind=docs + paths_touched = ["docs/foo.md"] → success
  - kind=docs + paths_touched = ["src/foo.py"] → escalated(kind_mismatch), rc=1
  - kind=docs + paths_touched = ["docs/foo.md", "src/bar.py"] → escalated(kind_mismatch)
  - kind=docs + paths_touched = ["skills/x.md", "agents/y.md", "CLAUDE.md", "README.md"] → success
  - kind=code + paths_touched = ["docs/foo.md"] → success（kind=code は境界 enforce 対象外）
- `tests/unit/migrate-add-kind-field.bats`: 既存 backlog に `kind="code"` を埋めることを確認、二度実行で diff 無し

### Integration tests

- `tests/integration/pbi-pipeline-doc-only.bats`: kind=docs PBI 用 pipeline トレース
  - design stage skip 確認
  - impl stage で pbi-implementer のみ spawn 確認
  - PBI Review で codex-impl-reviewer のみ spawn 確認
  - UT Run skip 確認
  - state.json 上で `design_status=skipped`, `ut_status=skipped`, `coverage_status=skipped` 確認
- `tests/integration/cross-review-doc-only.bats`: Sprint 全 PBI が kind=docs のとき aspect 2/3/4 reviewer 不起動を確認

### Lint tests

- `tests/lint/agents.bats`: pbi-implementer のフロントマター（既存 lint 流用）
- 新規スクリプトの shellcheck pass

## Rollout

1. PR-1: schema + wrapper（T1, T2）
2. PR-2: refinement + AC audit ゲート（T3）
3. PR-3: pbi-pipeline 改修（T4, T5）
4. PR-4: cross-review filter（T6）
5. PR-5: docs + migration（T7, T8）

各 PR は独立にレビュー可能。PR-1 がマージされるまで以降の PR は kind フィールドを読む側のロジックを実装できないため、PR-1 → 残りは並行可能。

## Risks / Open questions

- **Risk 1**: kind=docs の判定誤り（refinement で code PBI と誤判定 → UT 系全撤廃で品質ゲート抜け）
  - Mitigation: `mark-pbi-ready-to-merge.sh` の境界 enforce が code → docs 誤判定を遮断（paths_touched に非 .md が含まれていれば kind=docs PBI は escalate）。docs → code 誤判定の場合は UT が走るので過剰品質、害は少ない。
- **Risk 2**: AC 品質ゲートが既存 doc-only PBI を全て reject してしまう（kind=docs として永続化された後、grep 型 AC で詰む）
  - Mitigation: AC audit は refinement で実行され、verdict=needs_revision なら SM/PO が AC を書き直す。詰むのではなく差し戻し。
- **Risk 3**: aspect 1 reviewer が「grep ヒットではなく意味で判定」をうまく実行できない
  - Mitigation: prompt の Strict Rules で明文化。さらに `requirement-conformance-reviewer.md` agent 定義に kind=docs PBI 用の専用評価軸セクションを追加。
- **Open question**: doc-only PBI で impl round の termination gate（stagnation/divergence）はどう判定するか？ codex-impl-reviewer 単独のため verdict 取得は同じだが、gate ルールの再評価が必要かもしれない。
  - 暫定方針: code と同じルールを流用（impl_round の hard cap = 5, 同一 finding 連続 2 round で stagnation）。
- **Open question**: kind=docs PBI が cross-review aspect 1 で FAIL（要件適合不足）した場合の戻し先は？
  - 暫定方針: code と同じく `in_progress_impl` に戻し、`pbi-implementer` 再 spawn で fix。design stage は依然スキップ。

## Out-of-band coordination

- target project への migration script 適用は手動（framework 側でリモート push しない）
- framework repo 自身の `.scrum/` (integration test 用) にも migration 適用必要 → `scripts/setup-dev.sh` で実行する選択肢を検討
