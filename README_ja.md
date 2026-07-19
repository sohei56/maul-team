<p align="center">
  <img alt="Maul Team" src="images/maul-team.png" width="700">
</p>

<h1 align="center">Maul Team</h1>

<p align="center">
  <strong>Claude Code 向け AI Scrum チーム — Agent Teams によるマルチエージェント連携で Scrum ワークフローを丸ごと駆動</strong>
</p>

<p align="center">
  <a href="https://github.com/sohei56/maul-team/releases/latest"><img src="https://img.shields.io/github/v/release/sohei56/maul-team?style=flat-square&color=28c8e6&label=release" alt="Latest release"></a>
  <a href="https://github.com/sohei56/maul-team/releases"><img src="https://img.shields.io/github/downloads/sohei56/maul-team/total?style=flat-square&color=28c8e6&label=downloads" alt="Total downloads"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20%2B%20Commercial-blue?style=flat-square" alt="License: MIT + Commercial"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
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

<p align="center">
  <a href="https://github.com/sohei56/maul-team/releases/latest/download/MaulTeam.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-Apple_Silicon_%26_Intel-000000?style=for-the-badge&logo=apple&logoColor=white" alt="MaulTeam.app をダウンロード（macOS / Apple Silicon & Intel）"></a>
  &nbsp;
  <a href="https://sohei56.github.io/maul-team/"><img src="https://img.shields.io/badge/Website-See_it_in_action-28c8e6?style=for-the-badge&logo=safari&logoColor=white" alt="紹介ページ — チームが動く様子を見る"></a>
  <br>
  <sub>署名・Apple 公証済み · macOS 14+ · または <code>brew install --cask maul-team</code></sub>
</p>

## Why?

Vibeコーディングのスピードは魅力的ですが、開発が長期化すると全体の秩序を保つのが難しくなります。
一方で、Spec-Driven Development（SDD）は秩序を保ちやすいものの、初期段階で多くを定義する必要がある点が悩ましいところです。
実際のプロジェクトの多くはその中間にあり、最初からすべてが決まっているわけではない一方で、進めながらも全体の秩序を守っていく必要があります。

**Maul Team** は、Scrum の inspect-and-adapt ループを Claude Code に持ち込み、初日に完全な仕様を要求せずに構造化された反復を実現します。あなたは Product Owner の席に座り、作りたいものを伝え、Sprint Goal を承認し、各 Sprint で動くソフトウェアをレビューする — それ以外の作業は AI エージェントのチームが担います。

## デモ

<p align="center">
  <img alt="MaulTeam.app — 3ペインワークスペース" src="images/macapp-hero.png" width="900">
</p>

https://github.com/user-attachments/assets/3dac534a-e0f7-42a5-83be-899c3082e60b

**MaulTeam.app** は、スクラム開発に必要な情報と操作を 1 つのウィンドウにまとめるアプリです。

プロジェクトを選択または作成すると、埋め込みターミナルで Scrum Master と会話できます。さらに、ネイティブダッシュボードで Product や Sprint の状況、PBI 一覧、進捗を確認できます。Agent の活動や生成中のコードも確認できます。

## はじめに

いちばん簡単な入り口は **Mac App** — フレームワーク全体を包むネイティブ macOS アプリです。
Linux の方やターミナルを好まれる方は [コマンドライン](#コマンドライン-上級) を使うこともできます。

### インストール

**アプリをダウンロード** — 署名・Apple 公証済みの最新
[**MaulTeam.dmg**](https://github.com/sohei56/maul-team/releases/latest/download/MaulTeam.dmg)
をダウンロードして開き、**MaulTeam.app** を Applications へドラッグします。
Gatekeeper の警告なしに起動できます。過去のバージョンとリリースノートは
[Releases ページ](https://github.com/sohei56/maul-team/releases/latest) にあります。

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
| **macOS + Xcode** | macOS 14+ / Xcode 16+ (Swift 6 toolchain) | ソースビルド用。初回ビルド時は [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 取得のためネットワークアクセスが必要 |
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
5. **PBI Development (PBI ごとに並列)** — 各 Developer が担当 PBI の `pbi-pipeline` スキルを回す:
   - **worktree 分離 × 並列** — Developer ごとに専用の git worktree (`.scrum/worktrees/<pbi-id>/`, ブランチ `pbi/<pbi-id>`) で開発するため、PBI 同士が干渉せずに並走する
   - **クロスモデルレビュー** — design → implementation + black-box UT の各 Round を **Codex** がレビューし (未導入なら Claude ベースにフォールバック)、終了は決定論的なゲートで判定する
   - **マージはゲート制** — black-box UT が実測の C0/C1 カバレッジ付きで通り、5 観点の Integrity レビュー (requirement-conformance / functional-quality / security / maintainability / docs-consistency) がその PBI の diff を通過して初めて、SM がマージする
6. **Cross-Review** — 全 PBI のマージ後、SM が監査専任の cross-review を実行: リポジトリ全体への 4 軸 `codebase-audit` (spec-conformance / logic-defect / redundancy / product-security)。non-blocking で、Critical/High の指摘は次 Sprint の draft PBI になる
7. **Sprint Review** — SM がアプリを起動し、完了した PBI を順にデモ。あなたがそれぞれの動作を確認する
8. **Retrospective** — チームが振り返り、次 Sprint 以降への改善を記録する
9. Product Goal を達成するまで 3 に戻って**反復**。達成後、以下の 2 フェーズへ進む:
10. **Integration Tests** — 設計書から境界値・分岐網羅のテストケースを導出して実行 (smoke + API/UI 自動化)
11. **UAT & Release** — ユーザーストーリー駆動 UAT とリリース可否判定

</details>

## Product Owner としてのあなたの役割

これがデフォルトの **human-in-the-loop** モードです: デリバリーはチームが回し、あなたは要所のゲートでプロダクト判断を下します。

| あなたがやること | AI チームがやること |
|--------|-----------------|
| 何を作りたいかを伝える | 要件を引き出し、詳細に書き起こす |
| Sprint Goal を承認する | Sprint を計画し PBI を割り当てる |
| 動いているアプリでデモをレビューする | Increment を設計・実装し、cross-review を実行する |
| UAT で欠陥を報告する | 欠陥を修正し、再テストする |
| リリース判断を下す | 自動テストスイートを実行する |

> ループの中に座らない選択肢もあります。**自律モード** (`po_mode=agent`) では PO の席を `product-owner` エージェントに委譲します: 目指すべき状態をプロダクトブリーフで最初に指定すれば、あとはエージェント PO と Scrum Master がその状態に向かってスクラムを回し続けます — 下記 [Loop Engineering](#loop-engineering) の考え方です。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)。

## Loop Engineering

**Loop engineering (ループエンジニアリング)** は、単発のプロンプトではなく、エージェントが計画・実行・検証・改善を繰り返す仕組みを設計する考え方です。Maul Team はこれを **Development pipeline**、**Sprint**、**自律実行**の 3 層で実装しています。

- **Development pipeline ループ (最内 — 構築と検証)。** PBI ごとに専用の git worktree で、design → implementation + black-box unit test → Codex クロスモデルレビューの Round を、決定論的な終了ゲート (success / stagnation / divergence / hard cap) が通るまで反復する。テストとレビューを通過するまでマージは開かない。詳細は [Scrum 開発の流れ](#scrum-開発の流れ)。
- **Sprint ループ (中間 — ドリフト検出と自己改善)。** 各 Sprint の末尾で、マージ済みコードと要件・設計の乖離を検出するリポジトリ全体・4 軸の `codebase-audit` を実行する。Critical/High の指摘は次 Sprint の draft PBI として起票され、Retrospective も同じ形でプロセス改善を前へ送る。プロダクトとプロセスの双方が hill-climb する。*(LangChain の hill-climbing ループ。)*
- **自律実行ループ (最外 — イベント駆動・無人)。** 目指すべき状態をプロダクトブリーフとして一度指定すれば、PO の席さえエージェントになる (`po_mode=agent`): エージェント PO と Scrum Master がその状態に向かってスクラムを回し続け、外側の [Ralph-Loop](https://ghuntley.com/ralph/) ウォッチドッグがヘッドレスセッションをイテレーションのたびに再起動し、安全弁 (iterations / wall-clock / Sprints / failure budgets) を強制し、API のレート制限中はスリープして復帰し、朝レポートを書き出す。*(LangChain の event-driven ループ。)*

主なリスクは、ループの出力をそのまま受け入れてしまう **cognitive surrender (認知的な明け渡し)** です。Maul Team は、state-write とブランチのルール、決定論的なゲート、実測カバレッジ、曖昧な要件のエスカレーションによってこれを抑えます。

背景資料: [Addy Osmani「Loop Engineering」](https://addyosmani.com/blog/loop-engineering/)、[O'Reilly Radar](https://www.oreilly.com/radar/loop-engineering/)、[LangChain「The Art of Loop Engineering」](https://www.langchain.com/blog/the-art-of-loop-engineering)。

## 機能

- **ネイティブ Mac アプリ** — MaulTeam.app はチーム全体を 1 つの macOS ウィンドウで動かす (プロジェクトピッカー、埋め込み Scrum Master ターミナル、ファイルごとに独立ウィンドウで開くコードエディタ、native ダッシュボード)。
- **19 個の Skill でライフサイクル全体をカバー** — プロダクトブリーフ共同作成から要件定義・プランニング・PBI 開発・マージ・監査・レビュー・レトロスペクティブ、そして integration testing・UAT & release まで、すべてのセレモニーがバージョン管理された検査可能な Skill
- **マルチエージェント連携** — Scrum Master (Delegate モード) が Sprint あたり最大 6 並列の Developer (1 PBI に Developer 1 名、上限 6) を統括
- **ゲート制の並列開発** — Developer は分離された git worktree で PBI を並列に開発し、各 Round を Codex がクロスレビュー。black-box UT と Integrity レビューを通過した PBI だけがマージされる
- **自律モード (Loop Engineering)** — 目指すべき状態をプロダクトブリーフで指定し、PO の席さえ AI Product Owner に委譲。エージェント PO と Scrum Master がその状態に向かってスクラムをエンドツーエンドに回し続ける。外側の Ralph-Loop ウォッチドッグがヘッドレスの Claude セッションを再起動し、安全弁を強制しつつレポートを `.scrum/reports/` に書き出す。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)
- **設計書ガバナンス** — 不可変の catalog (`catalog.md`) + 編集可能な有効化設定 (`catalog-config.json`)をstatus-gate フックで強制することで、AIが作成するドキュメントを制御
- **品質フック** — status gate、path guard、branch-ops guard、作業完了時フローと Definition of Done のチェック、session context restoration、外部の stall watchdog — エージェントに守らせたい挙動を、スキップできない仕組みに変換
- **状態の永続化** — すべての状態を `.scrum/` の JSON ファイルに保存。セッション再開可能
- **Retrospective 駆動の改善** — 過去 Sprint の改善が自動的に反映される
- **自動テスト** — Integration Tests が設計駆動のテストケース (境界値、フロー/パターン分岐) を smoke test に加えて導出し、API + Playwright UI テストとしてコミット可能な形で自動化。続く UAT & Release がストーリー駆動 UAT とリリース判定を実行

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
 │  5. PBI Pipeline      Per Developer / per PBI, in parallel, │
 │                         each in its own git worktree:       │
 │                         design → impl + black-box UT →      │
 │                         Codex cross-model review, with      │
 │                         deterministic termination gates     │
 │                         and real C0/C1 coverage,            │
 │                         then a 5-aspect Integrity stage     │
 │          ▼                                                  │
 │  6. Per-PBI Merge     Gate: merge only after UT + review    │
 │                         pass (--no-ff + regression gate;    │
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

# あるいは: 自律モード — ブリーフでゴールを一度指定すれば、エージェント PO + SM が無人でループ
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
  [`macapp/LICENSE`](macapp/LICENSE) です。ソースからのビルドと
  個人利用・社内利用は現在無償です（将来のバージョンで Enterprise
  向け有償プランを導入する可能性があります）。再配布・転売・
  派生ビルドの配布は禁止されています。

コントリビューションには一度きりの
[Contributor License Agreement](docs/CLA.md) への署名が必要です。詳細は
[CONTRIBUTING.md](CONTRIBUTING.md#licensing-and-cla) を参照してください。
