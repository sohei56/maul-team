<p align="center">
  <img alt="Maul Team" src="images/maul-team.png" width="700">
</p>

<h1 align="center">Maul Team</h1>

<p align="center">
  <strong>Claude Code 向け AI Scrum チーム — Agent Teams によるマルチエージェント連携で Scrum ワークフローを丸ごと駆動</strong>
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20%2B%20Commercial-blue?style=flat-square" alt="License: MIT + Commercial"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Claude_Code-Agent_Teams-D97706?style=flat-square&logo=anthropic&logoColor=white" alt="Claude Code Agent Teams">
  <img src="https://img.shields.io/badge/python-3.9%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+">
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>日本語</strong>
</p>

<p align="center">
  <a href="#why">Why?</a> &bull;
  <a href="#デモ">デモ</a> &bull;
  <a href="#はじめに">はじめに</a> &bull;
  <a href="#loop-engineering">Loop Engineering</a> &bull;
  <a href="#機能">機能</a> &bull;
  <a href="#コマンドライン-上級">コマンドライン</a> &bull;
  <a href="#アーキテクチャ">アーキテクチャ</a> &bull;
  <a href="#開発">開発</a>
</p>

---

**MaulTeam.app** を開く（あるいはターミナルで `scrum-start.sh` を実行する）と、AI による Scrum チームが立ち上がります。**Scrum Master** が **Developer** エージェントを束ねて Sprint を回し、あなたは **Product Owner** としてゴールを承認し、動くプロダクトをレビューします。

## Why?

Vibeコーディングのスピードは魅力的ですが、開発が長期化すると全体の秩序を保つのが難しくなります。
一方で、Spec-Driven Development（SDD）は秩序を保ちやすいものの、初期段階で多くを定義する必要がある点が悩ましいところです。
実際のプロジェクトの多くはその中間にあり、最初からすべてが決まっているわけではない一方で、進めながらも全体の秩序を守っていく必要があります。

**Maul Team** は、Scrum の inspect-and-adapt ループを Claude Code に持ち込み、初日に完全な仕様を要求せずに構造化された反復を実現します。あなたは Product Owner の席に座り、作りたいものを伝え、Sprint Goal を承認し、各 Sprint で動くソフトウェアをレビューする — それ以外の作業は AI エージェントのチームが担います。

## デモ

<p align="center">
  <img alt="MaulTeam.app — 3ペインワークスペース" src="images/macapp-hero.png" width="900">
</p>

https://github.com/user-attachments/assets/e71c5fc3-b269-4df3-a585-f5da03e292bc

**MaulTeam.app** は、スクラム開発に必要な情報と操作を 1 つのウィンドウにまとめるアプリです。

プロジェクトを選択または作成すると、埋め込みターミナルで Scrum Master と会話できます。さらに、ネイティブダッシュボードで Product や Sprint の状況、PBI 一覧、進捗を確認できます。Agent の活動や生成中のコードも確認できます。

## はじめに

いちばん簡単な入り口は **Mac App** — フレームワーク全体を包むネイティブ macOS アプリです。
Linux の方やターミナルを好まれる方は [コマンドライン](#コマンドライン-上級) を使うこともできます。

### インストール

**アプリをダウンロード** — 署名・Apple 公証済みの最新 `.dmg` を
[**Releases ページ**](https://github.com/sohei56/maul-team/releases/latest)
から入手し、開いて **MaulTeam.app** を Applications へドラッグします。
Gatekeeper の警告なしに起動できます。

**または Homebrew で:**

```bash
brew tap sohei56/homebrew-tap
brew install --cask maul-team
```

<details>
<summary>ソースからビルドする場合</summary>

```bash
git clone git@github.com:sohei56/maul-team.git
cd maul-team
sh macapp/scripts/make-app.sh release
open macapp/build/MaulTeam.app
```

</details>

**必要要件:**

| 要件 | バージョン | 用途・備考 |
|------|-----------|-----------|
| **macOS + Xcode** | macOS 13+ / Xcode 15+ (Swift 5.9+) | ソースビルド用。初回ビルド時は [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 取得のためネットワークアクセスが必要 |
| **Claude Code CLI** | 2.1.172 以上 (PATH 上) | アプリは `scrum-start.sh` を実行し、その PBI パイプラインはサブエージェントがさらにサブエージェントを spawn する機能 (2.1.172 で解禁) に依存。[Claude Code のバージョン](#claude-code-のバージョン) 参照 |
| **Python** | 3.9+ | `scrum-start.sh` が起動時に検証し、無ければ `textual` + `watchdog` を導入 (Mac App 自身のダッシュボードは native SwiftUI だが、ランチャは依然これらを確認する) |
| **Codex CLI** | 任意・推奨 | クロスモデルレビューを有効化。未導入の場合、レビュー工程は Claude ベースのレビューにフォールバック |

エディタ、バックグラウンドセッション、同梱フレームワークの解決、配布状況を含むアーキテクチャ全体は [macapp/README.md](macapp/README.md) を参照。

### Scrum 開発の流れ

概要は、**要件を整理 → Sprint を計画 → PBI を並列で開発・レビュー → 動くプロダクトをデモ → 改善して反復**、という流れです。

<details>
<summary>詳細なライフサイクル</summary>

1. **プロダクトブリーフを共同作成する** — 新規プロジェクトでは `docs/product/brief.md` を対話的に共同執筆する。ブリーフが以降の開発の土台になる
2. **要件定義** — Scrum Master が Requirements Analyst を spawn し、要件を引き出して `requirements.md` を書く
3. **Backlog Refinement** — SM が要件から PBI を作成・洗練する
4. **Sprint Planning** — SM が Sprint Goal を提案し、あなたが承認または調整する
5. **PBI Development (PBI ごとに並列)** — 各 Developer は conductor として、自分が担当する PBI 専用の git worktree (`.scrum/worktrees/<pbi-id>/`, ブランチ `pbi/<pbi-id>`) で `pbi-pipeline` スキルを走らせる。design → implementation + black-box UT → review（Codex が利用可能ならクロスモデル、未導入なら Claude ベースにフォールバック）のラウンドを、決定論的な終了ゲートと実測の C0/C1 カバレッジで回す。ready-to-merge の前には Integrity ステージとして 5 つの観点別レビュー (requirement-conformance / functional-quality / security / maintainability / docs-consistency) がその PBI の diff に対して走る。PBI 完了時には SM がマージする。
6. **Cross-Review** — 全 PBI のマージ後、SM が監査専任の cross-review を実行: リポジトリ全体への 4 軸 `codebase-audit` (spec-conformance / logic-defect / redundancy / product-security)。non-blocking で、Critical/High の指摘は次 Sprint の draft PBI になる
7. **Sprint Review** — SM がアプリを起動し、完了した PBI を順にデモ。あなたがそれぞれの動作を確認する
8. **Retrospective** — チームが振り返り、次 Sprint 以降への改善を記録する
9. Product Goal を達成するまで 3 に戻って**反復**。達成後、以下の 2 フェーズへ進む:
10. **Integration Tests** — 設計書から境界値・分岐網羅のテストケースを導出して実行 (smoke + API/UI 自動化)
11. **UAT & Release** — ユーザーストーリー駆動 UAT とリリース可否判定

</details>

## Product Owner としてのあなたの役割

| あなたがやること | AI チームがやること |
|--------|-----------------|
| 何を作りたいかを伝える | 要件を引き出し、詳細に書き起こす |
| Sprint Goal を承認する | Sprint を計画し PBI を割り当てる |
| 動いているアプリでデモをレビューする | Increment を設計・実装し、cross-review を実行する |
| UAT で欠陥を報告する | 欠陥を修正し、再テストする |
| リリース判断を下す | 自動テストスイートを実行する |

> PO の席は `po_mode=agent` (自律モード) で `product-owner` エージェントに委譲することもできます。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)。

## Loop Engineering

**Loop engineering (ループエンジニアリング)** は、単発のプロンプトではなく、エージェントが計画・実行・検証・改善を繰り返す仕組みを設計する考え方です。Maul Team はこれを **Development pipeline**、**Sprint**、**自律実行**の 3 層で実装しています。

- **Development pipeline ループ (最内 — 構築と検証)。** PBI ごとに design → implementation + black-box unit test → review を、決定論的な終了ゲート (success / stagnation / divergence / hard cap) が通るまで Round として反復する。Codex が利用可能ならクロスモデルレビューを行い、未導入なら Claude ベースのレビューにフォールバックする。C0/C1 カバレッジは実測ツールで計測する。
- **Sprint ループ (中間 — ドリフト検出と自己改善)。** 各 Sprint の末尾で、マージ済みコードと要件・設計の乖離を検出するリポジトリ全体・4 軸の `codebase-audit` を実行する。Critical/High の指摘は次 Sprint の draft PBI として起票され、Retrospective も同じ形でプロセス改善を前へ送る。プロダクトとプロセスの双方が hill-climb する。*(LangChain の hill-climbing ループ。)*
- **自律実行ループ (最外 — イベント駆動・無人)。** プロダクトブリーフを共同作成すれば、PO の席さえエージェントになる (`po_mode=agent`)。外側の [Ralph-Loop](https://ghuntley.com/ralph/) ウォッチドッグがヘッドレスセッションをイテレーションのたびに再起動し、安全弁 (iterations / wall-clock / Sprints / failure budgets) を強制し、API のレート制限中はスリープして復帰し、朝レポートを書き出す。*(LangChain の event-driven ループ。)*

主なリスクは、ループの出力をそのまま受け入れてしまう **cognitive surrender (認知的な明け渡し)** です。Maul Team は、state-write とブランチのルール、決定論的なゲート、実測カバレッジ、曖昧な要件のエスカレーションによってこれを抑えます。

背景資料: [Addy Osmani「Loop Engineering」](https://addyosmani.com/blog/loop-engineering/)、[O'Reilly Radar](https://www.oreilly.com/radar/loop-engineering/)、[LangChain「The Art of Loop Engineering」](https://www.langchain.com/blog/the-art-of-loop-engineering)。

## 機能

- **ネイティブ Mac アプリ** — MaulTeam.app はチーム全体を 1 つの macOS ウィンドウで動かす (プロジェクトピッカー、埋め込み Scrum Master ターミナル、タブ式コードエディタ、native ダッシュボード)。
- **19 個の Skill** で Scrum ライフサイクル全体をカバー: プロダクトブリーフ共同作成、要件抽出、バックログリファインメント、スプリントプランニング、PBI Development (design + impl + UT + per-PBI review)、per-PBI merge、cross-review (リポジトリ全体の codebase audit)、sprint review、retrospective、integration testing、UAT & release
- **マルチエージェント連携** — Scrum Master (Delegate モード) が Sprint あたり最大 6 並列の Developer (1 PBI に Developer 1 名、上限 6) を統括
- **自律 PO モード** — AI Product Owner でPOさえもエージェントに置き換えて開発をエンドツーエンドに駆動。外側の Ralph-Loop ウォッチドッグ がヘッドレスの Claude セッションを再起動し、安全弁を強制しつつレポートを `.scrum/reports/` に書き出す。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)
- **設計書ガバナンス** — 不可変の catalog (`catalog.md`) + 編集可能な有効化設定 (`catalog-config.json`)をstatus-gate フックで強制することで、AIが作成するドキュメントを制御
- **品質フック** — status gate、path guard、branch-ops guard、作業完了時フロー強制 (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`)、quality gate (Definition of Done)、session context restoration、加えて human モードでは外部の stall watchdog (`scripts/stall-watchdog.sh`)でエージェントに守らせたい挙動を仕組み化
- **状態の永続化** — すべての状態を `.scrum/` の JSON ファイルに保存。セッション再開可能
- **Retrospective 駆動の改善** — 過去 Sprint の改善が自動的に反映される
- **自動テスト** — Integration Tests が smoke test (unit + e2e) に加えて境界値・フロー/パターン分岐網羅の設計駆動テストケースを導出し、API テスト + Playwright UI テストとしてコミット可能な形で自動化。続く UAT & Release が Playwright MCP / Chrome DevTools MCP 支援のストーリー駆動 UAT とリリース判定を実行

### AI 特有の適応

これは人間の Scrum をそのままコピーしたものではなく、AI エージェントの実態に合わせてフレームワークを調整しています。

**AI の強みを活かす拡張:**

- **動的なチームサイジング** — Developer エージェントの数は、PBI 数と複雑度に応じて Sprint ごとに最適化される
- **二層の独立レビュー** — Increment を 2 つの粒度で検査する: マージ前に各 PBI の diff (5 観点の Integrity ゲート)、続いて Sprint 末にマージ後の Increment 全体へのリポジトリ全体 codebase audit。加えて、Codex が利用可能なら PBI 単位のクロスモデルレビューを実施し、未導入なら Claude ベースのレビューにフォールバックする。観点・軸の一覧は [Scrum 開発の流れ](#scrum-開発の流れ) を参照

**AI の弱点を抑え込む制約:**

- **必須の Requirement Definition** — 最初の Sprint (Sprint 0) は要件抽出専用。地図のないまま走り出すのを防ぐ
- **PBI なしの作業は禁止** — すべての開発は backlog item に紐付ける必要があり、Scrum Master が会話の途中で場当たり的な修正に流れることを防ぐ
- **ドキュメント作成の制限** — design catalog に列挙された種別のドキュメントのみ作成可能。AI が膨大かつ無秩序なドキュメントを生み出す傾向を抑制
- **PO 駆動の Sprint スコープ** — Sprint の境界は velocity 推定ではなく意味のあるレビューチェックポイントで設定。AI エージェントには安定した velocity の基準がない

### Sprint ライフサイクル

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Requirement Definition (Sprint 0)                          │
 │  Requirements Elicitation ──▶ Initial Product Backlog       │
 └──────────────────────────────┬──────────────────────────────┘
                                ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  Sprint N                                                   │
 │                                                             │
 │  1. Backlog Refine    PBIs: draft ──▶ refined               │
 │          ▼                                                  │
 │  2. Planning          PO approves Sprint Goal               │
 │          ▼                                                  │
 │  3. Scaffold Specs    Create design doc stubs from catalog  │
 │          ▼                                                  │
 │  4. Spawn Teammates   Launch Developer agents + worktrees   │
 │          ▼                                                  │
 │  5. PBI Pipeline      Per Developer / per PBI, in parallel: │
 │                         design → impl + black-box UT →      │
 │                         review (Codex when available), with │
 │                         deterministic termination gates     │
 │                         and real C0/C1 coverage,            │
 │                         then a 5-aspect Integrity stage     │
 │          ▼                                                  │
 │  6. Per-PBI Merge     SM merges each ready PBI immediately  │
 │                         (--no-ff + regression gate;         │
 │                         3-strike escalation)                │
 │          ▼                                                  │
 │  7. Cross-Review      Whole-repo 4-axis codebase-audit      │
 │                         (audit-only, non-blocking;          │
 │                         findings → next-Sprint draft PBIs)  │
 │          ▼                                                  │
 │  8. Sprint Review     Demo to PO, accept/reject PBIs        │
 │          ▼                                                  │
 │  9. Retrospective     Record improvements for next Sprint   │
 └──────────┬──────────────────────────┬───────────────────────┘
            │                          │
            ▼                          ▼
     Next Sprint N+1   ┌──────────────────────────────┐   ┌──────────────────────────┐
                       │  Integration Tests           │──▶│  UAT & Release           │
                       │  Smoke ──▶ Design-Driven     │   │  Story-Driven UAT ──▶    │
                       │  Cases ──▶ Stub/Automate     │   │  Release Decision        │
                       └──────────────────────────────┘   └──────────────────────────┘
```

## コマンドライン (上級)

ターミナル派、あるいはヘッドレス・リモート・Linux で動かしたい？ 同じフレームワークがシェルから動きます。

```bash
# リポジトリを clone
git clone git@github.com:sohei56/maul-team.git

# 自分のプロジェクトディレクトリで:
cd /path/to/your/project

# Scrum チームを起動 (必要なら Python 依存を自動インストール)
sh /path/to/maul-team/scrum-start.sh

# あるいは: 自律 PO モードで起動 (キーボード前に人間が不要)
sh /path/to/maul-team/scrum-start.sh --autonomous --brief docs/product/brief.md
```

このスクリプトはClaude Code (Scrum Master) と TUI ダッシュボードを伴う tmux セッションを起動します。

<p align="center">
  <img alt="scrum-start.sh demo" src="images/demo.gif" width="800">
</p>

> すでにこのフレームワークを導入済みのプロジェクトがある場合は `scrum-start.sh` を再実行して `.claude/` を更新してください。`.claude/` はコピーであり live link ではないため、Skill などの変更は再実行して初めて反映されます。

詳しいセットアップ手順は [quickstart.md](docs/quickstart.md) を、自律モードの運用 (安全弁、Stop-block 予算、朝レポート) は [docs/autonomous-mode.md](docs/autonomous-mode.md) を参照。

### コマンドラインの前提条件

- **Claude Code CLI** ≥ **2.1.172** と **Python 3.9+** — [はじめに](#はじめに) の共通前提条件を参照
- **tmux** (推奨) — ダッシュボードを横に並べるため

#### Claude Code のバージョン

`scrum-start.sh` は Claude Code が **2.1.172** より前のバージョンの場合に警告を表示します。**サブエージェントがさらにサブエージェントを spawn する機能は Claude Code 2.1.172 で解禁されました** ([changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md))。

アップグレード方法:

- **Homebrew** — 標準の `claude-code` cask は 2.1.153 で固定されているため、rolling-release cask に切り替える:
  ```bash
  brew uninstall --cask claude-code
  brew install --cask claude-code@latest
  ```
- **ネイティブインストーラ** — `curl -fsSL https://claude.ai/install.sh | bash`

`~/.claude/` 配下のセッション・メモリ・設定は、どちらのアップグレードでも保持されます。

## アーキテクチャ

```text
maul-team/
├── scrum-start.sh    # エントリポイント。--autonomous --brief <file> --max-sprints <N> をサポート
├── macapp/           # ネイティブ macOS シェル (SwiftUI + SwiftTerm): プロジェクトピッカー、
├── agents/           # Agents
├── skills/           # Skills
├── hooks/            # 動作と品質の担保ゲート
├── rules/            # 横断的 Scrum コンテキスト (team map、SSOT の所在、通信規約)。
├── dashboard/app.py  # Textual TUI (Sprint Overview / PBI Board / Work Log。CLI 経路用)
├── scripts/          # ステータスライン、ユーザー/コントリビューターセットアップ、
├── docs/design/      # catalog.md (読取専用) + catalog-config.json (有効化リスト) 
└── .scrum/           # 実行時の状態 (JSON、gitignore)
```

## 開発

開発環境のセットアップとワークフローは [CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## License

本リポジトリはライセンスが分かれています。

- **フレームワーク**（`macapp/` 以外のすべて）は
  [MIT License](LICENSE) のオープンソースです。
- `macapp/` 配下の **Mac アプリ**はソース公開型の商用ライセンス
  [`macapp/LICENSE`](macapp/LICENSE) です。ソースからのビルドと、
  個人利用・社内利用は自由ですが、再配布・転売・派生ビルドの配布は
  禁止されています。

コントリビューションには一度きりの
[Contributor License Agreement](docs/CLA.md) への署名が必要です。詳細は
[CONTRIBUTING.md](CONTRIBUTING.md#licensing-and-cla) を参照してください。
