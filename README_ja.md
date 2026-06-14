<p align="center">
  <img alt="claude-scrum-team" src="images/claude-scrum-team.png" width="700">
</p>

<h1 align="center">claude-scrum-team</h1>

<p align="center">
  <strong>Claude Code 向け AI Scrum チーム — Agent Teams によるマルチエージェント連携で Scrum ワークフローを丸ごと駆動</strong>
</p>

<p align="center">
  <a href="https://github.com/sohei56/claude-scrum-team/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sohei56/claude-scrum-team?style=flat-square&color=blue" alt="License"></a>
  <img src="https://img.shields.io/badge/python-3.9%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 3.2+">
  <img src="https://img.shields.io/badge/Claude_Code-Agent_Teams-D97706?style=flat-square&logo=anthropic&logoColor=white" alt="Claude Code Agent Teams">
  <img src="https://img.shields.io/badge/TUI-Textual-7C3AED?style=flat-square" alt="Textual TUI">
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>日本語</strong>
</p>

<p align="center">
  <a href="#why">Why?</a> &bull;
  <a href="#デモ">デモ</a> &bull;
  <a href="#機能">機能</a> &bull;
  <a href="#クイックスタート">クイックスタート</a> &bull;
  <a href="#アーキテクチャ">アーキテクチャ</a> &bull;
  <a href="#開発">開発</a>
</p>

---

任意のプロジェクトディレクトリで `scrum-start.sh` を実行すると、AI による Scrum チームが立ち上がります。**Scrum Master** が **Developer** エージェントを束ねて Sprint を回し、あなたは **Product Owner** としてゴールを承認し、動くプロダクトをレビューします。

## Why?

Vibeコーディングのスピードは魅力的ですが、開発が長期化すると全体の秩序を保つのが難しくなります。
一方で、Spec-Driven Development（SDD）は秩序を保ちやすいものの、初期段階で多くを定義する必要がある点が悩ましいところです。
実際のプロジェクトの多くはその中間にあり、最初からすべてが決まっているわけではない一方で、進めながらも全体の秩序を守っていく必要があります。

**claude-scrum-team** は、Scrum の inspect-and-adapt ループを Claude Code に持ち込み、初日に完全な仕様を要求せずに構造化された反復を実現します。あなたは Product Owner の席に座り、作りたいものを伝え、Sprint Goal を承認し、各 Sprint で動くソフトウェアをレビューする — それ以外の作業は AI エージェントのチームが担います。

## デモ

<p align="center">
  <img alt="scrum-start.sh demo" src="images/demo.gif" width="800">
</p>

ワンコマンドでエージェント・スキル・フックをセットアップし、Scrum Master エージェントと tmux 上のリアルタイム TUI ダッシュボードを伴った Claude Code を起動します。

### セッションの流れ

1. **プロジェクトを説明する** — Scrum Master が Developer を spawn し、要件を引き出して `requirements.md` を書く
2. **Backlog Refinement** — SM が要件から PBI を作成・洗練する
3. **Sprint Planning** — SM が Sprint Goal を提案し、あなたが承認または調整する
4. **PBI Pipeline (PBI ごとに並列)** — 各 Developer は conductor として、自分が担当する PBI 専用の git worktree (`.scrum/worktrees/<pbi-id>/`, ブランチ `pbi/<pbi-id>`) で `pbi-pipeline` スキルを走らせる。design → implementation + black-box UT → cross-model (Codex) review のラウンドを、決定論的な終了ゲートと実測の C0/C1 カバレッジで回す。PBI 完了時には SM がその場で即マージ (`--no-ff` + per-merge regression gate、3 連敗で escalation)。
5. **Cross-Review** — 全 PBI のマージ後、SM が Sprint 成果物 全体に対して 5 つの観点別レビュー sub-agent (requirement-conformance / functional-quality / security / maintainability / docs-consistency) を並列に spawn
6. **Sprint Review** — SM がアプリを起動し、完了した PBI を順にデモ。あなたがそれぞれの動作を確認する
7. **Retrospective** — チームが振り返り、次 Sprint への改善を記録する
8. Product Goal を達成するまで **反復**。その後 **Integration Sprint** が smoke test、設計書完全性検証、ユーザーストーリー駆動 UAT を実行する

## 機能

- **17 個の Skill** (Scrum セレモニー 16 + PO acceptance 1) で Scrum ライフサイクル全体をカバー: 要件抽出、バックログリファインメント、スプリントプランニング、PBI pipeline (design + impl + UT + per-PBI review)、per-PBI merge、cross-review、sprint review、retrospective、integration testing
- **マルチエージェント連携** — Scrum Master (Delegate モード) が Sprint あたり最大 6 並列の Developer (1 PBI に Developer 1 名、上限 6) を統括
- **自律 PO モード** (`--autonomous`) — AI Product Owner (`po_mode=agent`) でチームをエンドツーエンドに駆動。外側の Ralph-Loop ウォッチドッグ (`scripts/autonomous/watchdog.sh`) がヘッドレスの Claude セッションを再起動し、安全弁 (iterations / wall clock / Sprints / budget) を強制しつつ朝レポートを `.scrum/reports/` に書き出す。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)
- **リアルタイム TUI ダッシュボード** — Textual ベースの 3 ペイン表示 (Sprint Overview / PBI Progress Board / agent メッセージ + work イベント統合の Work Log)。watchdog によるファイルシステム監視付き
- **設計書ガバナンス** — 不可変の catalog (`catalog.md`) + 編集可能な有効化設定 (`catalog-config.json`)をstatus-gate フックで強制することで、AIが作成するドキュメントを制御
- **品質フック** — status gate、path guard、branch-ops guard、作業完了時フロー強制 (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`)、quality gate (Definition of Done)、session context restoration、加えて human モードでは外部の stall watchdog (`scripts/stall-watchdog.sh`)でエージェントに守らせたい挙動を仕組み化
- **状態の永続化** — すべての状態を `.scrum/` の JSON ファイルに保存。セッション再開可能
- **自動テスト** — Integration Sprint が smoke test (unit + e2e)、設計書完全性検証、オプションの Playwright MCP による browser E2E、ストーリー駆動 UAT を実行
- **Retrospective 駆動の改善** — 過去 Sprint の改善が自動的に反映される

### AI 特有の適応

これは人間の Scrum をそのままコピーしたものではなく、AI エージェントの実態に合わせてフレームワークを調整しています。

**AI の強みを活かす拡張:**

- **動的なチームサイジング** — Developer エージェントの数は、PBI 数と複雑度に応じて Sprint ごとに最適化される
- **独立した cross-review** — Sprint 成果物 全体に対して 5 つの観点別レビュー sub-agent (`requirement-conformance-reviewer` / `functional-quality-reviewer` / `security-reviewer` / `maintainability-reviewer` / `docs-consistency-reviewer`) を並列に spawn。PBI 単位の Codex-CLI cross-model review を実施

**AI の弱点を抑え込む制約:**

- **必須の Requirements Sprint** — 最初の Sprint は要件抽出専用。地図のないまま走り出すのを防ぐ
- **PBI なしの作業は禁止** — すべての開発は backlog item に紐付ける必要があり、Scrum Master が会話の途中で場当たり的な修正に流れることを防ぐ
- **ドキュメント作成の制限** — design catalog に列挙された種別のドキュメントのみ作成可能。AI が膨大かつ無秩序なドキュメントを生み出す傾向を抑制
- **PO 駆動の Sprint スコープ** — Sprint の境界は velocity 推定ではなく意味のあるレビューチェックポイントで設定。AI エージェントには安定した velocity の基準がない

### Sprint ライフサイクル

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Requirements Sprint (Sprint 0)                             │
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
 │                         cross-model (Codex) review, with    │
 │                         deterministic termination gates     │
 │                         and real C0/C1 coverage             │
 │          ▼                                                  │
 │  6. Per-PBI Merge     SM merges each ready PBI immediately  │
 │                         (--no-ff + regression gate;         │
 │                         3-strike escalation)                │
 │          ▼                                                  │
 │  7. Cross-Review      SM spawns 5 aspect reviewer agents    │
 │          ▼                                                  │
 │  8. Sprint Review     Demo to PO, accept/reject PBIs        │
 │          ▼                                                  │
 │  9. Retrospective     Record improvements for next Sprint   │
 └──────────┬──────────────────────────┬───────────────────────┘
            │                          │
            ▼                          ▼
     Next Sprint N+1   ┌───────────────────────────────────────┐
                       │  Integration Sprint                   │
                       │  Smoke ──▶ Design-Completeness ──▶    │
                       │  Story-driven UAT ──▶ Release         │
                       └───────────────────────────────────────┘
```

## クイックスタート

```bash
# リポジトリを clone
git clone git@github.com:sohei56/claude-scrum-team.git

# 自分のプロジェクトディレクトリで:
cd /path/to/your/project

# Scrum チームを起動 (必要なら Python 依存を自動インストール)
sh /path/to/claude-scrum-team/scrum-start.sh

# あるいは: 自律 PO モードで起動 (キーボード前に人間が不要)
sh /path/to/claude-scrum-team/scrum-start.sh \
   --autonomous --brief docs/product/brief.md --max-sprints 3
```

このスクリプトは前提条件を検証し (`textual` と `watchdog` が無ければ自動インストール)、エージェント定義・Skill・フック・共通ルール・design catalog を対象プロジェクトの `.claude/` ディレクトリへコピーし、Claude Code (Scrum Master) と TUI ダッシュボードを伴う tmux セッションを起動します。

詳しいセットアップ手順は [quickstart.md](docs/quickstart.md) を、自律モードの運用 (安全弁、予算、朝レポート) は [docs/autonomous-mode.md](docs/autonomous-mode.md) を参照。

### 前提条件

- **Claude Code CLI** がインストール済みで PATH 上にあること — **2.1.172 以上を推奨** ([Claude Code のバージョンについて](#claude-code-のバージョンについて) 参照)
- **Python 3.9+** と `textual`・`watchdog`
- **tmux** (推奨) — ダッシュボードを横に並べるため

#### Claude Code のバージョンについて

`scrum-start.sh` は Claude Code が **2.1.172** より前のバージョンの場合に警告を表示します。PBI パイプライン (`pbi-pipeline` Skill) は Developer サブエージェントがさらに専門サブエージェント (`pbi-designer` / `pbi-implementer` / `pbi-ut-author` / `codex-{design,impl,ut}-reviewer`) を spawn することに依存しています。**サブエージェントがさらにサブエージェントを spawn する機能は Claude Code 2.1.172 で解禁されました** ([changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md))。これより古いバージョンでは Developer の tool 一覧に `Agent` / `Task` が存在せず、PBI パイプラインは Design 段階で停止します。

アップグレード手順:

- **Homebrew** — 標準の `claude-code` cask は 2.1.153 で停止しているため、rolling release 版 cask へ切り替えます:
  ```bash
  brew uninstall --cask claude-code
  brew install --cask claude-code@latest
  ```
- **Native installer** — `curl -fsSL https://claude.ai/install.sh | bash`

`~/.claude/` 配下のセッション・メモリ・設定はどちらのアップグレード経路でも保持されます。

### Product Owner としてのあなたの役割

| あなたがやること | AI チームがやること |
|--------|-----------------|
| 何を作りたいかを伝える | 要件を引き出し、詳細に書き起こす |
| Sprint Goal を承認する | Sprint を計画し PBI を割り当てる |
| 動いているアプリでデモをレビューする | Increment を設計・実装し、cross-review を実行する |
| UAT で欠陥を報告する | 欠陥を修正し、再テストする |
| リリース判断を下す | 自動テストスイートを実行する |

> PO の席は `po_mode=agent` (自律モード) で `product-owner` エージェントに委譲することもできます。決定は `.scrum/po/decisions.json` に永続化されます。詳細は [docs/autonomous-mode.md](docs/autonomous-mode.md)。

## アーキテクチャ

- **`scrum-start.sh`** — エントリポイント: 前提条件の検証、`scripts/setup-user.sh` を内部で実行して agents / skills / hooks / rules を対象プロジェクトにコピー、続けて tmux を起動。`--autonomous --brief <file> --max-sprints <N>` をサポート
- **`agents/`** — トップレベル 3 エージェント (Delegate モードの Scrum Master、Developer、Product Owner) + 11 個の specialist sub-agent (cross-review reviewer 5 + PBI Pipeline sub-agent 6、Codex-CLI cross-model reviewer 含む)。カタログ: [docs/contracts/sub-agents.md](docs/contracts/sub-agents.md)
- **`skills/`** — Inputs / Outputs を必須とした 17 個の Skill (Scrum セレモニー 16 + PO acceptance 1)
- **`hooks/`** — Status gate、path guard、branch-ops guard、単一 Stop エントリ (`stop-dispatch.sh` → `dashboard-event.sh` + `completion-gate.sh`)、quality gate、session context。加えて `scripts/stall-watchdog.sh` (human モードの teammate-stall 外部監視)
- **`rules/`** — 横断的な Scrum コンテキスト (team map、SSOT の所在、コミュニケーションプロトコル)。`.claude/rules/` 経由で全エージェントに自動ロード
- **`dashboard/app.py`** — リアルタイムパネル (Sprint Overview / PBI Board / Work Log) を持つ Textual TUI
- **`scripts/`** — ステータスライン、ユーザーセットアップ、コントリビューターセットアップ、自律モードウォッチドッグ (`scripts/autonomous/`)
- **`.scrum/`** — 実行時の状態 (JSON、gitignore)
- **`docs/design/`** — `catalog.md` (読み取り専用) + `catalog-config.json` (有効化リスト) に統治される設計書群

PBI 単位の cross-model レビューは `codex-{design,impl,ut}-reviewer` sub-agent が担い、OpenAI Codex CLI (`codex`) を shell out で呼び出します。同梱の MCP-server ブリッジは不要です。

## 開発

開発環境のセットアップとワークフローは [CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## License

[MIT](LICENSE)
