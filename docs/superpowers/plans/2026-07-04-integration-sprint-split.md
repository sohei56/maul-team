# Integration Sprint 2 スキル分割 + テスト体系化 作業計画

- **作成日**: 2026-07-04
- **対象**: `skills/integration-sprint/` とその配線一式
- **目的**: Integration Sprint を「Integration Tests」と「UAT & Release」の
  2 スキルに分割し、設計書駆動の体系的テスト(境界値・フロー分岐・
  パターン分岐網羅、外部 IF スタブ、自動化ファースト)と、PO エージェントが
  Playwright MCP / Chrome DevTools MCP で自走できる UAT を実現する
- **実施体制**: 実装は Opus 以下のサブエージェントに WP 単位で移譲。
  メインセッションは計画・レビュー・監査のみ

---

## 1. ユーザー要求(2026-07-04)

1. `integration-sprint` を **Integration Tests** と **UAT & Release** の
   2 ステップ(2 スキル)に分割する。
2. Integration Tests:
   - 設計書から**体系的にテストケースを作成**する。
   - ローカル再現不能な外部 IF は必要に応じて **Stub を構築**する。
   - その上で API / 画面を実際に叩き、**設計通りか**をテストする。
   - **境界値・フロー分岐・パターン分岐を網羅**する。
   - テストは**なるべく自動化**(API テスト用・画面操作用ライブラリを使用)。
     自動化できないものだけ Claude もしくは人間の打鍵でテストする。
3. UAT: **Playwright MCP / Chrome DevTools MCP** を使い、Claude の PO
   (po_mode=agent) でもテストを実施できるようにする。

## 2. 現状把握(事実)

- `skills/integration-sprint/SKILL.md` は 10 ステップの単一スキル。
  Step 1–5 がテスト(smoke-test 委譲 → design-completeness-check 委譲 →
  品質ゲート)、Step 6–10 が UAT・欠陥収集・PBI 化・リリース判定・
  CLAUDE.md 再生成。分割線は Step 5/6 の間に自然に引ける。
- `skills/smoke-test/SKILL.md`: フレームワーク検出 → 既存テスト実行 →
  HTTP smoke → (Playwright MCP があれば)ブラウザ E2E。結果は
  `.scrum/scripts/record-test-result.sh` 経由で
  `.scrum/test-results.json` に category 単位で upsert、
  `overall_status` は wrapper が再計算。
- `skills/design-completeness-check/SKILL.md`: 有効 spec
  (`docs/design/catalog-config.json`)から**機能インベントリ**
  (1 機能 = 1 検証、happy-path 粒度)を導出し、実行系に対して検証、
  `design_completeness` category を追記。境界値・分岐網羅の概念はない。
- `skills/po-acceptance/SKILL.md` (mode=uat): PO teammate が
  requirements.md から US を全数導出し、1 ストーリーずつ runnable
  command(CLI / HTTP / Playwright MCP)で検証。既に Playwright MCP
  言及あり(`SKILL.md:150`)。Chrome DevTools MCP への言及は repo 内に無し。
- 配線(変更が波及する箇所):
  - phase enum: `docs/contracts/scrum-state/state.schema.json:18`、
    `scripts/scrum/update-state-phase.sh:15`
  - `hooks/completion-gate.sh:246,274,485` — integration_sprint は
    test-results.json の overall_status でゲート、passed なら
    checkpoint として allow
  - `scripts/autonomous/watchdog.sh:351` — integration_sprint 再開時の
    SM への指示文
  - `docs/contracts/agent-interfaces.md:93,120` — スキル一覧表
  - `tests/lint/skill-frontmatter.bats:22` — lint 対象スキル名リスト
  - `CLAUDE.md:14` — 「18 Skills」の数とディレクトリ一覧、phase フロー
    記述、`README.md` / `README_ja.md`
  - `scripts/setup-user.sh:109-118` — skills/*/ を汎用コピー
    (references/ 含む。**新スキル追加自体は無変更で配布される**)。
    `:217` PO 許可リスト `mcp__playwright`、`:359-413` MCP 設定
    (context7 + playwright のみ。chrome-devtools は無い)
- `docs/design/catalog.md` は読み取り専用カタログ。テスト関連 spec は
  S-050 Test Strategy のみ。テストケース一覧の spec type は無い。

## 3. 設計判断(2026-07-04 ユーザー裁定済)

### D1: phase enum を `integration_sprint` / `uat_release` に分離【裁定】

ユーザー裁定(2026-07-04): サブステップ方式ではなく **phase enum を
分離**する。`integration_sprint` = Integration Tests 実行フェーズ、
新設 `uat_release` = UAT & Release フェーズ。

**Phase 遷移**(変更後):

```
retrospective ──(sprint_continuation: integration_sprint)──▶ integration_sprint
integration_sprint ──(tests passed)─────────────────────────▶ uat_release
integration_sprint ──(defect PBIs 起票)─────────────────────▶ backlog_created
uat_release ──(release go)──────────────────────────────────▶ complete
uat_release ──(UAT 欠陥 / no_go)────────────────────────────▶ backlog_created
```

`retrospective` からの入口と sprint_continuation の選択肢名
(`integration_sprint`)は不変。enum は追加のみで既存値を変えないため、
デプロイ済みプロジェクトの既存 state.json は後方互換(§7 注意参照)。

**配線変更点**(WP0 として実装):

- `docs/contracts/scrum-state/state.schema.json:18` — enum に
  `uat_release` 追加。
- `scripts/scrum/update-state-phase.sh:15` — 許可リストに追加。
- `hooks/completion-gate.sh` — `integration_sprint` 分岐(:485)は
  現行どおり test-results ゲート(passed で allow = checkpoint)。
  **新設 `uat_release` 分岐**: `.scrum/po/uat-stories-<sprint-id>.md`
  が存在し全 US に verdict があれば allow、無ければ block
  (「uat-release スキルを実行せよ」)。autonomous checkpoint リスト
  (:274 `complete|retrospective|integration_sprint`)に `uat_release`
  を追加。
- `scripts/autonomous/watchdog.sh:351` — `integration_sprint` の
  指示文を「integration-tests を実行。passed → `uat_release` へ遷移、
  欠陥 → `backlog_created`」に書き換え、**新設 `uat_release` case**
  (「uat-release スキルで UAT → リリース判定を駆動」)を追加。
- `docs/data-model.md` / `CLAUDE.md` / `docs/autonomous-mode.md` /
  `docs/contracts/agent-interfaces.md` の phase フロー記述を更新。

**表示ラベル**(WP8 として実装):

| 表示面 | 箇所 | integration_sprint | uat_release |
|---|---|---|---|
| Mac App | `macapp/Sources/ScrumTeam/Views/DashboardView.swift:233`(現 `"Integration Tests & UAT"`) | `"Integration Tests"` | `"UAT & Release"` |
| Textual ダッシュボード | `dashboard/app.py:146` PHASE_FLOW(現 `("integration_sprint", "Integration")`) | `Integration Tests` | `UAT & Release` |

Textual 側は PHASE_FLOW に無い phase を赤の unknown 表示にするため
(`app.py:160`)、`uat_release` の追加は表示崩れ防止として必須。

### D2: design-completeness-check は integration-tests に吸収【承認済】

新スキルのテストケース設計(§4.1)は機能インベントリ方式の上位互換
(全機能列挙 ⊂ 全機能 × 境界値 × 分岐)。2 本並存させると検証の二重管理に
なる。吸収して `skills/design-completeness-check/` は削除。
`design_completeness` category は新スキルの「設計網羅」カテゴリ
(`design_coverage`)に置換し、completion-gate は category 名に依存して
いない(overall_status のみ参照)ため影響なし。
**smoke-test は独立スキルとして残す**(integration-tests の Step 1 として
委譲。既存テスト資産の回帰確認という別役割があるため)。

### D3: ブラウザ MCP は Playwright 主 + Chrome DevTools 追加【承認済】

- 自動化テストコード(§4.1)は **MCP ではなく Playwright 本体**
  (`npx playwright test`)で書き、リポジトリにコミット(再実行可能な資産)。
- Claude 打鍵(自動化不能ケース + UAT)は Playwright MCP を主経路、
  Chrome DevTools MCP(`chrome-devtools-mcp`)を補助
  (console/network 検査・パフォーマンストレースが必要なケース)として
  `setup-user.sh` の MCP 設定と PO 許可リストに追加。どちらも無ければ
  従来どおり graceful skip + 警告。

### D4: 成果物の置き場所【承認済】

- **自動テストコード**: 対象プロジェクトの `tests/integration/`・
  `tests/e2e/`(言語慣習に従う)にコミット = 永続資産。
- **テストケースマトリクス + トレーサビリティ**:
  `.scrum/integration-tests/<sprint-id>/test-cases.md`(実行時成果物)。
- **スタブ**: 対象プロジェクトの `tests/stubs/` にコミット、テスト
  ランナーから起動/停止(テスト外では使わない)。
- catalog.md への新 spec type 追加はしない(読み取り専用ガバナンスを
  回避。テスト戦略が必要なら既存 S-050 を使う)。

## 4. 新スキル設計

### 4.1 `skills/integration-tests/` (SKILL.md + references/)

```
skills/integration-tests/
  SKILL.md                       # オーケストレーション(下記 Step 1-7)
  references/
    test-case-design.md          # 設計書→テストケース導出方法論
    stub-construction.md         # 外部 IF スタブ構築プロトコル
    test-automation.md           # 自動化ファースト実装規約
```

**Steps(SKILL.md)**:

1. phase を `integration_sprint` に遷移(現行 Step 1 と同じ wrapper)。
2. テスト担当 Developer teammate を spawn(spawn-teammates)。
3. **smoke-test スキル委譲**(既存資産の回帰。現行 Step 3 と同じ)。
4. **テストケース設計**(references/test-case-design.md):
   有効 spec 全件からテストケースマトリクスを導出し
   `.scrum/integration-tests/<sprint-id>/test-cases.md` に書く。
   カテゴリ別導出規則:
   - S-020..023 (Interface): エンドポイント × パラメータごとに
     同値分割 + **境界値**(min/max/空/null/型・形式違反)、
     エラー応答契約(4xx/5xx)、認証・認可境界。
   - S-040 (Business Rule): **デシジョンテーブル**で条件組み合わせ
     (パターン分岐)を網羅。閾値は境界値 ±1。
   - S-042 (Workflow/State Machine): **状態遷移網羅**(全遷移 ≥1 回、
     不正遷移の拒否確認)= フロー分岐網羅。
   - S-030..034 (UI): 画面遷移網羅(S-033)、フォーム検証境界値、
     ユーザージャーニー(S-034)を E2E フロー化。
   - S-022 (External Integration): スタブ前提シナリオ
     (正常 / 異常応答 / タイムアウト / 不正形式)。
   - 各ケースに `id` / `source`(spec anchor) / 入力・期待値 /
     `automation`(automated | claude-manual | human-manual)を付与。
   - **トレーサビリティ**: spec の全分岐・全境界 ⇄ テストケース ID の
     対応表。未カバー項目は 0 件、または理由付き waive 必須
     (design-completeness-check の uncovered-list 規律を継承)。
5. **スタブ構築**(references/stub-construction.md):
   ローカル再現不能な外部 IF を列挙 → S-022 spec の契約から
   スタブを実装(`tests/stubs/`)。方式の優先順位: OpenAPI 定義があれば
   契約駆動モック(prism 等) → 言語ネイティブのモックサーバ
   (MSW / WireMock 等) → 最小の手書き fixture サーバ。
   接続切替は環境変数(本番コードにスタブ分岐を埋め込まない)。
6. **テスト自動化 + 実行**(references/test-automation.md):
   - API → プロジェクト言語のテストライブラリ
     (pytest+httpx / supertest / go test 等)で
     `tests/integration/` に実装。
   - 画面 → **Playwright(コード)** で `tests/e2e/` に実装。
   - 自動化不能ケースのみ: Claude 打鍵(Playwright MCP /
     Chrome DevTools MCP で操作し、証跡をログ+スクリーンショットで
     記録)→ それも不能なら human-manual として PO/ユーザーに提示する
     チェックリストへ。**自動化率(automated / 全ケース)をレポート**。
   - 結果は record-test-result.sh で category 記録:
     `integration_api` / `integration_ui` / `design_coverage`(旧
     design_completeness 相当の網羅判定)/ claude-manual 分は
     `manual_probe`。verdict 規律(pass/fail/missing/not_testable、
     missing は fail 扱い)は design-completeness-check から継承。
7. **品質ゲート + SM 報告**(現行 Step 5 を移植):
   failed → 欠陥リスト提示 → PBI 化 → `backlog_created` へ
   (Development Sprint ループ)。passed → SM へ完了報告し、SM が
   phase を `uat_release` に遷移して uat-release を起動する。
   **修正は必ず PBI 経由**(現行規律を維持)。

**Strict Rules**(継承+新規): テスト実装者はプロダクトコードを修正
しない / spec の主張を弱めて pass させない / スタブは spec 契約の写像
のみ(挙動の発明禁止)/ 未カバー分岐の黙殺禁止。

### 4.2 `skills/uat-release/` (SKILL.md + references/)

現行 Step 6–10 を移植し、PO の実打鍵を強化:

```
skills/uat-release/
  SKILL.md                       # UAT → 欠陥収集 → PBI 化 → リリース判定
  references/
    po-browser-uat.md            # PO の MCP 打鍵プロトコル
```

**Steps**:

1. phase を `uat_release` に遷移
   (`.scrum/scripts/update-state-phase.sh uat_release`)。
   前提確認: `test-results.json.overall_status ∈ {passed,
   passed_with_skips}`(未達なら phase を `integration_sprint` に
   戻して integration-tests に差し戻し)。
   integration-tests の human-manual チェックリストと not_testable
   一覧を UAT 前口上に含める(現行 Step 6b の規律を継承)。
2. **UAT**(現行 Step 6 を移植):
   - human mode: 現行どおり US を 1 件ずつユーザー打鍵。
   - agent mode: PO teammate が po-acceptance (mode=uat) を実行。
     **強化点**: references/po-browser-uat.md に基づき、UI を持つ US は
     Playwright MCP で navigate / click / form-fill / スクリーンショット
     取得まで行い、証跡を `.scrum/po/uat-<sprint-id>.md` の US
     アンカーに残す。表示崩れ・console エラー・ネットワーク失敗の検査が
     必要な US は Chrome DevTools MCP を併用。MCP 不在時は
     runnable-command 検証にフォールバック(既存規律)。
3. 欠陥収集 → PBI 化(現行 Step 7–8 を移植。po_mode=agent の
   PO_ACCEPTANCE_REPORT 集約・defect_triage 一括化も現行どおり)。
4. Development Sprint への差し戻し(現行 Step 9。
   `max_integration_cycles` 再突入キャップも現行どおり移植)。
5. リリース判定 + CLAUDE.md 再生成 + phase `complete`
   (現行 Step 10。`append-po-decision.sh` の go ゲートも現行どおり)。

**po-acceptance への追記**(別 WP): mode=uat の検証手段に
Chrome DevTools MCP を追加し、UI ストーリーは「ブラウザ打鍵 +
スクリーンショット証跡」を第一選択とする 1 節を追加。

## 5. 作業パッケージ(サブエージェント移譲単位)

各 WP は independent なら並列可。モデルは全 WP とも Opus 以下
(推奨: WP1/WP2 = Opus、WP3–6 = Sonnet)。

| WP | 内容 | 主な成果物 | 依存 |
|---|---|---|---|
| WP0 | phase enum 分離(§3 D1): state.schema.json、update-state-phase.sh、completion-gate.sh(`uat_release` 分岐新設 + checkpoint リスト追加)、watchdog.sh(`uat_release` case 新設 + integration_sprint 指示文更新)、対応する bats テスト追加/更新 | schema・sh・hook 差分 + テスト | なし |
| WP1 | `skills/integration-tests/` 新規作成(§4.1。SKILL.md + references/ 3 本。smoke-test 委譲・record-test-result 連携・ゲート移植含む) | SKILL.md, references/*.md | なし |
| WP2 | `skills/uat-release/` 新規作成(§4.2)+ `skills/po-acceptance/SKILL.md` への Chrome DevTools MCP / ブラウザ証跡追記 | SKILL.md, references/po-browser-uat.md, po-acceptance 差分 | なし |
| WP3 | 旧スキル退役: `skills/integration-sprint/` と `skills/design-completeness-check/` を削除し、参照箇所を新スキルへ張り替え | 削除 + 参照更新 | WP1, WP2 |
| WP4 | 配線更新: CLAUDE.md(スキル数・一覧・phase フロー記述)、docs/data-model.md phase 遷移、docs/contracts/agent-interfaces.md:93,120 + Stop Hook 節、README.md / README_ja.md、docs/autonomous-mode.md | 各差分 | WP0, WP3 |
| WP5 | `scripts/setup-user.sh`: chrome-devtools MCP を .mcp.json 生成/追記に追加、PO 許可リストに `mcp__chrome-devtools` 追加。tests/lint/skill-frontmatter.bats のスキル名リスト更新 | setup-user.sh, bats 差分 | WP1, WP2 |
| WP6 | 検証: `bats tests/unit/ tests/lint/` 全緑、`shellcheck` 対象全緑、旧スキル名の残存 grep 0 件(docs/superpowers/ の履歴文書は除外)、frontmatter lint 通過 | テスト結果報告 | WP0–5 |
| WP7 | レビュー: 別サブエージェントによる cross-check(新 SKILL.md が po_mode 両対応か、escalation 経路を発明していないか、no-private-project-references 遵守か、design-completeness-check の規律が全量移植されているか) | レビュー報告 | WP6 |
| WP8 | 表示ラベル(§3 D1 表): `macapp/.../DashboardView.swift:233` を `integration_sprint → "Integration Tests"` + `uat_release → "UAT & Release"` に、`dashboard/app.py` PHASE_FLOW に `uat_release` 追加(`Integration Tests` / `UAT & Release`)。`ruff check dashboard/` 緑 | Swift + Python 差分 | WP0 |

実施順: (WP0 ∥ WP1 ∥ WP2) → WP3 → (WP4 ∥ WP5 ∥ WP8) → WP6 → WP7。

## 6. 明示的な非スコープ

- record-test-result.sh wrapper の変更(category 名は自由形式。
  実装者は着手時に schema/wrapper が任意 category 名を許すことを確認し、
  違えばこの計画に差し戻す)。
- smoke-test スキルの改修(現行のまま integration-tests から委譲)。
- sprint_continuation の選択肢名変更(`integration_sprint` のまま。
  入口の意味は不変)。

## 7. リスク・注意

- **enum 追加は後方互換**(既存値を変えない)だが、デプロイ済み
  プロジェクトが旧 `integration-sprint` スキルの途中で止まっている
  場合、再 setup 後は新フローで再開される。phase が
  `integration_sprint` のままなら integration-tests から自然に
  再入できる(test-results.json の upsert 特性により再実行は安全)。
- Chrome DevTools MCP のパッケージ名・起動引数は実装時に**必ず Web
  検索で最新を確認**(pbi-designer の library-selection 規律と同じ。
  訓練データの記憶で書かない)。
- 削除する design-completeness-check の規律(uncovered 0 件、
  not_testable 理由必須、missing=fail、検証者はコードを直さない)は
  新スキルに**全て**移植されていることを WP7 で照合する。

## 8. WP7 レビュー結果と追補(2026-07-04 実施後追記)

WP7 独立レビュー: blocker 0 / major 3 / minor 4。観点 1-5(po_mode
両対応・escalation 経路・規律全量移植・配線整合・no-private-refs)は
pass。major 3 件は一点に収束:**テスト資産(tests/integration/ 等)の
コミット機構が未定義**で、Developer の Strict Rules 3 本
(No-implementation-without-PBI / Worktree boundary /
Commits-via-commit-pbi.sh)と字面衝突し、`commit-pbi.sh` は
`pbi/*` ブランチ専用のため D4(資産の永続コミット)を満たす
サンクション経路が存在しなかった。

**採択した解決(案 a)**: 専用 wrapper
`scripts/scrum/commit-integration-tests.sh` を新設(WP9)。
phase=integration_sprint 必須、pbi/* ブランチ拒否、ステージ対象を
tests/{integration,e2e,stubs}/ + 明示 `--allow` パスに限定し、
許可リスト外の混入はコミット拒否。developer.md の 3 規律には
Integration Tests 例外を明記済(テスト資産は正規成果物、
プロダクトソースは引き続き PBI 必須)。minor 4 件
(Start-gate 残骸行 / 起動失敗規律の再明文化 /
test-results.schema.json 冒頭 description / data-model.md ASCII、
+ scrum-state README への retired 注記)も WP9 で是正。
- 対象プロジェクトへの配布は setup-user.sh の汎用コピーで自動追従する
  が、**既存デプロイ済みプロジェクトは再 setup が必要**(README に
  移行注記を 1 行足す — WP4 に含める)。
