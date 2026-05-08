# Completion-gate `in_flight_hint` カバレッジ調査 + SM re-spawn loop 根本対処

**Status:** Open — investigation pending
**Created:** 2026-05-08
**Owner:** sohei (継続セッション着手予定)
**Predecessor work:** commit `24fdd7c` (in_flight_hint 導入), commit `28dcf72` (block message 圧縮)
**Related open items:** `docs/superpowers/plans/2026-05-07-cleanup-audit.md` OD-3 / OD-5 / T4-7

このファイルは**セッションを跨いだ引き継ぎ**を目的とする。次セッションは
このファイルだけ読めば全文脈を再構築できることを意図している。

---

## 1. 一次問題 (b): SM が Stop hook ブロックを誤読し re-spawn loop に入る

並列 PBI パイプライン中、Scrum Master (SM) が `completion-gate.sh` の
ブロック出力を「サブエージェントが失敗した」と誤読して同じ teammate を
再 spawn してしまうことがある。ログから観測された具体例は
`24fdd7c` のコミットメッセージに記録 (cross-review 中 65s で同じ
reviewer を 3 回 spawn など)。

**既存の緩和策:**
- `agents/scrum-master.md:176-190` "Background Subagent + Stop Hook Reading"
  セクション (24fdd7c で追加) — TaskGet を経由してから判断するルール
- `hooks/completion-gate.sh:58-64` `in_flight_hint()` — block 時に
  実行中サブエージェント数を併記し「WAIT — do NOT re-spawn」を促す
- `28dcf72` で block message を ~73% 圧縮 (誤読の機会自体を縮小)

---

## 2. 残課題: `in_flight_hint` のイベント出自カバレッジ未確認

### 2.1 ハイレベル仮説 (要検証)

`in_flight_hint()` は `dashboard.json` の `subagent_start` /
`subagent_stop` イベントを `agent_id` 単位で突き合わせて in-flight 数を
算出する (`hooks/completion-gate.sh:37-52`)。

- これらのイベントは `dashboard-event.sh` が Claude Code の
  `SubagentStart` / `SubagentStop` フックから書き込む
  (`hooks/dashboard-event.sh:319-360`)
- `setup-user.sh:308-322` で deployed 先 `.claude/settings.json` に
  `SubagentStart` / `SubagentStop` matcher 登録

**問題:** Claude Code の `SubagentStart` / `SubagentStop` イベントが、
Scrum Master が `Agent` ツールで spawn する **Teammate (top-level Agent)**
発火するのか、それとも sub-agent (同一セッション内の Task spawn) のみで
発火するのか、ランタイム未検証。

`pbi_pipeline_active` 中に動いているのは Developer **Teammates** であり、
sub-agents ではない。もし `SubagentStart` が Teammate 発火しないなら、
`count_in_flight_subagents` は常に 0 を返し → in_flight_hint は
appended されず → SM は「Stop hook がブロックしているのに何も走って
いない」と読み、結果的に 24fdd7c 以前と同じ誤読パターンに戻る可能性が
ある。

### 2.2 既知のヒント (すでに調査済の周辺事実)

- `hooks/dashboard-event.sh:2` のヘッダコメントは
  "PostToolUse/TeammateIdle/Stop/TaskCompleted/SubagentStart/SubagentStop"
  と列挙し、`SubagentStart` ブランチのコメント (`:320`) は
  "Teammate/subagent starting work" と書いている → **コードの意図上は
  両方を扱うつもり**だが実証は別問題
- `setup-user.sh` には `TeammateIdle` matcher が**別途**登録されている
  (`:298-306`) → Claude Code が両イベントを区別している傍証
- 関連既存タスク `OD-3` (cleanup-audit 2026-05-07) でも
  `TaskCompleted`, `TeammateIdle`, `SubagentStart`, `FileChanged`, `Agent`
  matcher の発火確認が要件として未消化
  (`docs/superpowers/plans/2026-05-07-cleanup-audit.md:34`)

---

## 3. 検証手順 (次セッションの最初のアクション)

### 3.1 ランタイム発火確認 (OD-3 と兼ねる)

**目的:** Teammate spawn 時に `SubagentStart` / `SubagentStop` /
`TaskCompleted` が発火するかを実証する。

**手段案 A — ライブ環境観測:**
1. ターゲットプロジェクトで `scrum-start.sh` を起動
2. `pbi_pipeline_active` 状態に到達した時点で `.scrum/dashboard.json`
   をストリーム監視 (`tail -f .scrum/dashboard.json` 相当)
3. SM が Developer teammate を spawn した瞬間に
   - `subagent_start` イベントが書き込まれるか (= フック発火 + コード経路 OK)
   - `agent_id` が teammate を識別できる値か
4. Developer 完了時に `subagent_stop` が対応 `agent_id` で書き込まれるか

**手段案 B — 一時 smoke スクリプト:**
- `tests/integration/` に最小スクリプトを配置し、`Agent` ツール経由の
  spawn → `dashboard.json` 差分を assert
- 注意: `Agent` ツール自体は Claude Code セッション内でしか使えないので
  unit test では再現不可。実セッション + bash の組合せが必要

### 3.2 確認すべき分岐

| 観測 | 解釈 | 次手 |
|------|------|------|
| Teammate spawn で `subagent_start` 発火、`agent_id` も付く | `in_flight_hint` 動作中。問題は別所 (UX/SM プロンプト) | §4.1 へ |
| Teammate spawn で `subagent_start` 発火**しない** | hint 機能は cross-review reviewer のみで効いている。pbi_pipeline_active では無効化されている | §4.2 へ |
| 発火するが `agent_id` が空 / セッション ID で重複 | カウント精度が不正確。`dashboard-event.sh:325-340` の payload 抽出を要修正 | §4.3 へ |

---

## 4. 修正パス (検証結果に対応)

### 4.1 `subagent_*` が Teammate もカバーしている場合

→ `in_flight_hint` のロジックは正しい。残る問題は **SM 側の prompt
解釈** または **block message が圧縮されてもなお冗長**。

候補:
- `agents/scrum-master.md:176-190` "Background Subagent + Stop Hook
  Reading" セクションをさらに強調 (例: 一行サマリを冒頭に追加)
- block message に subagent count が **ゼロでも** 「Teammates are
  working in their own worktrees — check `.scrum/communications.json`」
  といったコンテキストを併記

### 4.2 `subagent_*` が Teammate をカバー**しない**場合 (有力仮説)

→ `in_flight_hint` は pbi_pipeline_active で**無効**。代替が必要。

**候補 a (推奨):** `count_in_flight_subagents` を Teammate カウントにも
拡張する。情報源候補:
- `.scrum/backlog.json` の `in_progress_*` 件数 (= 既に compressed
  message で計算済) を hint としても流用 → DRY
- `.scrum/communications.json` の最新 `agent_spawn` イベント
  - PostToolUse `Agent` matcher が記録 (`dashboard-event.sh` 内に
    `agent_spawn` ハンドリングあり、`docs/superpowers/plans/2026-05-06-cleanup-audit.md:189` T5-6 参照)
- Claude Code の `TeammateIdle` イベント (反対の信号) を時系列追跡

**候補 b:** Claude Code 側で Teammate 用イベントが別途存在するなら
それを subscribe (`AgentStart` / `AgentStop` 等の matcher 名を確認)

### 4.3 `agent_id` が信頼できない場合

→ `dashboard-event.sh:325-340` の `agent_id` 算出ロジックを修正。
現状: 親ハンドラの `agent_id` 変数 (上流参照、行番号要確認) を使用。
要 payload 経路追跡。

---

## 5. 完了条件 (DoD)

- [ ] §3.1 検証実施 → 結果を本ファイルに追記 (削除しない)
- [ ] §4.x のいずれかを実装
- [ ] `tests/unit/hooks.bats` に in_flight_hint がカバーする条件を
      明示するテスト追加 (現状 review phase の cross_review でしか
      テストされていない `hooks.bats:439-475`)
- [ ] 関連: `docs/superpowers/plans/2026-05-07-cleanup-audit.md` の
      OD-3 / OD-5 / T4-7 が同じ runtime 検証で消化可能 → 合体実施を検討
- [ ] 検証スクリプト (一時) を `tests/integration/` に残すか退役か判断

---

## 6. 関連ファイル (次セッションでの読み込み優先順)

1. `hooks/completion-gate.sh` — gate 本体 (`pbi_pipeline_active` ブランチ
   は §1 の commit で圧縮済)
2. `hooks/dashboard-event.sh:319-360` — subagent_start/stop ハンドラ
3. `agents/scrum-master.md:176-190` — Background Subagent ルール
4. `scripts/setup-user.sh:283-322` — Stop / TaskCompleted /
   TeammateIdle / SubagentStart / SubagentStop hook 登録
5. `tests/unit/hooks.bats:439-475` — in_flight_hint 既存テスト
6. `docs/superpowers/plans/2026-05-07-cleanup-audit.md` — OD-3 文脈
7. commit `24fdd7c` — `git show 24fdd7c` で根本原因のログ抜粋を再読
8. commit `28dcf72` — message 圧縮の前後比較

---

## 7. 注意事項 / 落とし穴

- **このフレームワーク repo 自体には Stop hook 未登録**。検証は必ず
  `setup-user.sh` で deploy したターゲットプロジェクト側で行う
  (`.claude/settings.json:69-72` 参照: framework 側は
  `pre-tool-use-scrum-state-guard.sh` のみ)
- worktree 跨ぎ: Developer teammates は worktree 内で動き、`.scrum -> ../../../.scrum`
  symlink で SSOT を共有。`dashboard.json` は単一だが、各セッションが
  並列で `append_dashboard_event` するため race の可能性あり
  (`hooks/dashboard-event.sh:append_dashboard_event` の同期方式を確認)
- `count_in_flight_subagents` は fail-open (`echo "0"`) なので、
  `dashboard.json` 不在時は hint なし → SM は「stale block?」と再誤読
  する余地あり。検証時はこの fail-open 経路を踏んでないか確認
- 修正案 §4.2 候補 a で `backlog.json` 由来の件数を流用する場合、
  既に圧縮 message に同じ情報を埋めているので、**hint との重複** に
  注意 (重複したら SM が二重カウントするかも)
