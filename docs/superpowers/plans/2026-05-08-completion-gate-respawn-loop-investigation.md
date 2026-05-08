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

- [x] §3.1 検証実施 → 結果を本ファイルに追記 (削除しない)
      → §8 (静的調査 Phase 0) + §11 (Phase 1) で記録済
- [x] §4.x のいずれかを実装
      → Phase 2.1 (block message inline guidance) + Phase 2.3
      (scrum-master.md 拡張) を実施。§4.2(a) は判断2 棄却、
      §4.2(b) は F1 棄却、§4.3 は不要 (F2)
- [x] `tests/unit/hooks.bats` に in_flight_hint がカバーする条件を
      明示するテスト追加 (現状 review phase の cross_review でしか
      テストされていない `hooks.bats:439-475`)
      → §11.4 通り、新規 Teammate guidance 文言含有 assertion
      (`emits compressed status-grouped count for pbi_pipeline_active`
      内に追加) で代替。既存 §439-475 は維持
- [x] 関連: `docs/superpowers/plans/2026-05-07-cleanup-audit.md` の
      OD-3 / OD-5 / T4-7 が同じ runtime 検証で消化可能 → 合体実施を検討
      → OD-3 は本セッションで**部分消化** (F1 公式 docs により
      Teammate 非発火 confirmed)。OD-5 / T4-7 は本 PR 対象外
- [x] 検証スクリプト (一時) を `tests/integration/` に残すか退役か判断
      → 該当なし (静的調査のみで完了、一時スクリプトを作成していない)

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

---

## 8. Phase 0 実施結果 (2026-05-08, セッション1)

§3.1 のうち**ライブ環境観測を行わずに静的調査のみで決着可能**と判断し
実施。結果、§3.2 表の第2分岐 (= 有力仮説) が confirmed、加えて
**第4分岐 (cross_review でも hint 機能していなかった疑い)** が新規発覚。

### 8.1 確定事実

**事実 F1 (一次ソース):** Claude Code 公式 docs
(`code.claude.com/docs/en/agent-teams.md`) によれば、
`SubagentStart` / `SubagentStop` hook は **Task ツール spawn の
sub-agent でのみ発火**、`Agent` ツール経由の Teammate では
**発火しない**。SubagentStart は同期実行、SubagentStop は非同期。

→ `in_flight_hint` は **pbi_pipeline_active で原理的に機能しない**。
Developer Teammate は `Agent` ツール spawn のため。

**事実 F2 (リポジトリ内データ):** `.scrum/dashboard.json`
(2026-03-05〜06 のセッションログ) を集計:
- `subagent_stop`: 4件 (cross-review reviewer 終了)
- `subagent_start`: **0件**
- 他に `file_changed`: 96件

`completion-gate.sh:42-51` の `count_in_flight_subagents()` は
start/stop を agent_id で group_by → last が start のものをカウント。
**start が常に欠損 → cross_review でも in-flight 数は常に 0**。

**事実 F3 (Q2 docs 不明部分):** `TeammateIdle` event の payload
schema (agent identifier field 名等) は **public docs 未記載**。
ライブ観測でしか確認不能。

### 8.2 §3.2 表との突合

| 計画書記述 (§3.2) | Phase 0 結果 |
|---|---|
| 第1行: 発火 + agent_id OK | ✗ 該当しない |
| 第2行: Teammate spawn で非発火 | **✓ confirmed (公式 docs F1)** |
| 第3行: 発火するが agent_id 不正 | ✗ 該当しない |
| (新規) 第4行: cross_review でも記録欠損 | **要 Phase 1 確認 (F2)** |

### 8.3 計画書 §4 候補との突合

| 候補 | Phase 0 後の評価 |
|---|---|
| §4.1 (SM prompt 補強) | **必要**。pbi_pipeline_active 特有の文言を追加すべき (現状 §176-190 は cross-review reviewer 想定のみ) |
| §4.2 候補 a (backlog.json 流用 hint) | **棄却** (判断2)。pbi_pipeline_active block message に既に in-flight count あり (`completion-gate.sh:230-238`)。重複は §7 注意事項通り SM 混乱を生む |
| §4.2 候補 b (Teammate 用 event subscribe) | **棄却**。F1 通り Teammate 用 SubagentStart 等は存在しない。`TeammateIdle` のみあるが反対の信号 (idle ≠ in-flight)、payload schema も未確認 (F3) |
| §4.3 (agent_id 修正) | **不要**。F2 が示すのは agent_id ではなく start event 自体の欠損 |

### 8.4 ユーザー判断結果 (本セッション内で確定)

- **判断1**: Phase 1 実施 (`git log scripts/setup-user.sh` で
  SubagentStart 登録時期を確認)
- **判断2**: §4.2 候補 a (backlog.json 流用) は **棄却**
- **判断3**: §4.1 + §4.2(候補 a 以外) **併用可**。
  DoD §5 第2項の「§4.x のいずれか」制約は緩和

---

## 9. 改訂版作業計画 (次セッション着手用)

### Phase 1 — SubagentStart 記録欠損の事実確認

**目的:** F2 の謎を解く。cross_review hint も死んでいたかを確定。

1. `git log --all --oneline -- scripts/setup-user.sh | head -30`
   - `SubagentStart` matcher 登録 commit を特定
2. `.scrum/dashboard.json` の最新 timestamp と比較
   - 登録 commit より dashboard.json が古い → 単なる古いデータ、
     cross_review では今は機能している可能性
   - 登録 commit より dashboard.json が新しい → **登録済みなのに
     event 来ていない**= バグ。Phase 2.2 のスコープ拡大
3. 結果を本ファイル §10 に追記 (削除しない)

### Phase 2 — 修正実装

**Phase 2.1 (確定スコープ): pbi_pipeline_active block message 直接強化**

`hooks/completion-gate.sh:230-238` の block message に以下を追加:

```text
PBI pipeline active: ${total} in-flight (${summary}). Teammates
work in worktrees — do NOT re-spawn. Verify with TaskGet (if you
spawned them in this session) or SendMessage probe before assuming
failure. Re-spawn only after confirming termination AND missing
artifact.
```

- `in_flight_hint()` の append には**頼らない** (F1 により Teammate 非発火)
- 判断2 通り、件数は backlog.json から既に取得しているのでそれを流用

**Phase 2.2 (Phase 1 結果依存): cross_review hint の扱い**

- ケース A (3月データが hook 登録前): 現状コードを維持。
  以後 cross_review で `in_flight_hint()` が機能する。
  hooks.bats に SubagentStart 経路の smoke test を追加して
  リグレッション防止
- ケース B (登録済みなのに非発火 = bug): 別調査タスク化。
  本 PR では `in_flight_hint()` を cross_review path のみで
  呼ぶように **意図を明示** (現状は block_stop 全経路で呼ぶ
  `:28`)、コメントで「pbi_pipeline_active では F1 により無効」
  と記載

**Phase 2.3 (確定スコープ): SM agent prompt 補強**

`agents/scrum-master.md:176-190` "Background Subagent + Stop Hook
Reading" セクションを以下に拡張:

- 既存 (cross-review reviewer 想定) はそのまま保持
- 新規節を追加: pbi_pipeline_active 中の Teammate 向け
  - 「Stop hook が `PBI pipeline active: N in-flight` を返したら、
    それは Teammate が worktree で作業中という意味」
  - 「Re-spawn 前に必ず `.scrum/communications.json` の最新
    `agent_spawn` / `status_change` を確認」
  - 「TaskGet は同一セッション内で spawn した場合のみ有効。
    永続 Teammate には SendMessage probe」

### Phase 3 — テスト + DoD クローズ

1. `tests/unit/hooks.bats`:
   - 既存 §439-475 (cross_review + in_flight_hint) は維持
   - 新規: pbi_pipeline_active block message に Teammate 文言が
     含まれることの assertion
   - Phase 1 ケース B の場合、SubagentStart smoke test を追加
2. `agents/scrum-master.md` の lint (markdown 構造のみ、本リポは
   markdown lint 自動化なし)
3. 計画書 §10 に Phase 1〜3 実施結果を追記 (削除しない)
4. 関連 plan `docs/superpowers/plans/2026-05-07-cleanup-audit.md` の
   OD-3 (= subagent event 発火確認) を **部分消化** として
   クロスリンク。OD-5 / T4-7 は別タスクのまま

### Phase 4 — DoD §5 完了確認

- [ ] §3.1 検証実施 → §8 で記録済 ✓ (本セッション)
- [ ] §4.x 実装 → Phase 2.1 + 2.3 (確定) + 2.2 (Phase 1 結果依存)
- [ ] hooks.bats テスト追加 → Phase 3.1
- [ ] OD-3/OD-5/T4-7 合体判断 → Phase 3.4
- [ ] 検証スクリプト退役判断 → 該当なし (静的調査のみで完了)

---

## 10. 次セッションでの最初のアクション (チェックリスト)

新セッションは以下の順で動くこと。本ファイル全文を読んでから着手。

1. **§9 Phase 1 を 1コマンドで実施**:
   ```
   git log --all --oneline --follow -- scripts/setup-user.sh | head -30
   git log -p --all -- scripts/setup-user.sh | grep -B2 -A2 "SubagentStart" | head -60
   ```
   結果を本ファイル §10 末尾に追記 (Phase 1 結果セクションを作る)。

2. **§9 Phase 2.2 ケース判定** (A or B) を本ファイルに記録

3. **§9 Phase 2.1 + 2.3 実装**:
   - `hooks/completion-gate.sh:230-238` の block message 編集
   - `agents/scrum-master.md:176-190` 節を拡張
   - 判断2 通り `in_flight_hint()` は呼び出し方を変更しない
     (= pbi_pipeline_active path では実質 no-op、§7 通り fail-open)

4. **§9 Phase 3 テスト**:
   - `bats tests/unit/hooks.bats` ローカル実行
   - assertion 追加 (Teammate 文言含有確認)

5. **コミット**: Conventional Commits 形式
   - `fix(completion-gate): inline teammate guidance in pbi_pipeline_active block message`
   - `docs(scrum-master): clarify Stop hook reading for pbi_pipeline_active`
   - `test(hooks): assert teammate guidance in pbi_pipeline_active block`

6. **本ファイル更新**: §5 DoD チェックリストを順次 [x] に。

### 制約 (絶対に踏まないこと)

- ❌ `in_flight_hint()` を pbi_pipeline_active path で呼ぶ拡張
  (F1 により Teammate 非発火。死コード化)
- ❌ backlog.json 由来件数を hint として block message に**追加で**
  混入させる (判断2 で棄却。重複は §7 注意事項違反)
- ❌ Claude Code セッションを起動して実機検証する作業
  (Phase 0 で静的に決着済、不要な API 課金回避)
- ❌ 計画書既存セクション §1-§7 の改変 (引き継ぎ証跡として保持)

### 既知の未消化項目 (本 PR 外)

- F3: `TeammateIdle` payload schema 確認 (将来 Teammate 用 hint
  実装したい場合のブロッカー)
- F2 ケース B 確定時: SubagentStart event 欠損の root cause 調査
- `cleanup-audit.md` OD-5 / T4-7 (本 PR でカバーしない)

---

## 11. Phase 1 結果 (2026-05-08, セッション2)

### 11.1 観測コマンド

```bash
git log --all --oneline -S "SubagentStart" -- scripts/setup-user.sh
# → 8b3643f (2026-03-04T21:55:25Z UTC = 2026-03-05 06:55:25 +0900)
git log --pretty='%H %ai' --reverse -- .claude/settings.json
# → 892d45e 2026-04-13 18:23:40 +0900 (初コミット)
grep -oE '"timestamp": "[^"]*"' .scrum/dashboard.json | head -1; tail -1
# → 2026-03-05T01:17:01Z 〜 2026-03-05T02:40:23Z UTC
grep -oE '"type": "[^"]*"' .scrum/dashboard.json | sort | uniq -c
# → 96 file_changed, 4 subagent_stop, 0 subagent_start
```

### 11.2 確定事実

- **F4**: `setup-user.sh` template への SubagentStart matcher 登録は
  commit `8b3643f` (2026-03-04T21:55:25Z) で導入済。
- **F5**: `.scrum/dashboard.json` の event 範囲は 2026-03-05T01:17:01Z
  〜 02:40:23Z (= F4 commit より約 3.5h 後)。subagent_start: 0,
  subagent_stop: 4, file_changed: 96。
- **F6 (盲点)**: framework repo 自身の `.claude/settings.json` は
  `SubagentStart` hook を**登録していない** (PreToolUse の
  `pre-tool-use-scrum-state-guard.sh` のみ)。`.claude/settings.json`
  自体の初コミットは 2026-04-13 で、F5 の event 収集時点では未追跡。
- F5 の dashboard.json は **framework dev session** のログ
  (agent_id "a2a46ae1" が `scripts/lib/check-python.sh` 等を編集している
  ことから、framework 自身の改修作業)。deploy 先 target project の
  ログではない。

### 11.3 §9 Phase 1 step 2 二択への評価 — 前提が誤りだった

§9 Phase 1 step 2 は「dashboard.json が登録 commit より新しい → 登録済みで
event 来ない = バグ」という二択を前提にしていたが、F6 により**第3の
ケース** (= dashboard.json は framework session 由来であり、
deploy 先 target project の挙動を本リポからは検証不能) が判明。
登録 commit の比較対象は「target project 側の hook 状態」であり、
framework 内の dashboard.json では証拠にならない。

→ §8.1 F2 の結論「cross_review でも in-flight 数は常に 0」は、
**framework session に対しては正しい** (hook 未登録) が、deploy 先で
同様の症状が出るかは本調査では未確定。

### 11.4 Phase 2.2 ケース判定

**ユーザー判断 (本セッション内 confirmed): (i) Case A 扱いで進める。**

- 現状コード (`hooks/completion-gate.sh:58-64` の `in_flight_hint()`) を
  維持。
- `hooks.bats` に SubagentStart 経路の smoke test 追加は§14 で扱う
  (既存 §439-475 が SubagentStart 含む dashboard.json 入力で
  `in_flight_hint` を呼び出す path を既に被覆しているため、追加 smoke
  test は新規の Teammate guidance 文言含有 assertion で兼ねる)。
- リスク: 将来 deploy 先で実は SubagentStart が発火していなかったと
  判明した場合は再調査。`§9 既知の未消化項目 F2 ケース B` に該当。

### 11.5 制約遵守確認

- ❌ `in_flight_hint()` を pbi_pipeline_active で呼ぶ拡張: **不採用**
  (block_stop 経由で結果的に呼ばれるが、Teammate 非発火により常に空文字
  返却 = no-op。コード変更なし)。
- ❌ backlog.json 由来件数を hint として block message に追加で混入:
  **不採用** (既に :230-238 で in_flight_total を使用、二重計上なし)。
- ❌ Claude Code セッション起動: 未実施 (F4-F6 は静的調査のみで決着)。
- ❌ §1-§7 改変: 未実施 (本追記は §11 として末尾に新設)。

