# OD-5 Verification Checklist (2026-06-12)

cleanup-audit OD-5 で導出された **target-project 実機検証 3 項目** を 1
ターンで確認するための手順書。フレームワーク repo (このリポジトリ) では
登録されていない hook と、フレームワーク repo に存在しない alias の
実機挙動を確かめる。

## 前提

- 任意の target project 配下で `sh /path/to/claude-scrum-team/scrum-start.sh`
  実行済 (または `setup-user.sh` で `.claude/` 一式デプロイ済)
- `.scrum/config.json` で `po_mode: "agent"` を設定 (Item 1 用)
- 別ターミナルで `tail -f .scrum/communications.json` および `.scrum/dashboard.json`
  を見られる状態

## Item 1: `claude-fable-5` alias が解決するか

**背景**: `agents/product-owner.md` の `model: claude-fable-5` は公開 alias
一覧に該当無し。spawn 試行で確証する。

**手順**:
```
（SM ペインで実行）
（テスト用に PO への 1 件の dummy 質問を SendMessage で送る）
```

具体的には `.scrum/communications.json` への append-communication 経由で
`[test] PO_DECISION_REQUEST kind=spec_clarification ...` を 1 件入れ、
Stop すると SM が product-owner teammate を spawn する流れを観察する。
あるいは autonomous-PO モードで 1 iteration 回す方が簡単 (autonomous
watchdog が PO を spawn するため)。

**期待**:
- product-owner teammate が `claude-fable-5` で spawn → 成功
- もしくは "unknown model" 系の API エラーが Claude Code 側で出る → **要対応**

**結果記録**:
- [ ] spawn 成功 (alias 実在) — そのまま運用継続
- [ ] spawn 失敗 (`unknown model` 等) — `agents/product-owner.md:9` を有効な
      alias (`opus` / `claude-opus-4-7` 等) に修正、bats も合わせて再修正

## Item 2: `PostToolUse` matcher で `SendMessage` / `Agent` が発火するか

**背景**: `scripts/setup-user.sh:270` heredoc が PostToolUse の matcher に
`Agent` と `SendMessage` を含めている。`hooks/dashboard-event.sh:206,227` に
対応ハンドラが存在するが、Claude Code が実際に PostToolUse をこれら
メタツールで発火するかは未確認。

**手順**:
1. SM ペインから明示的に `Agent(subagent_type="developer", ...)` を 1 回起動
2. 起動完了直後に `.scrum/dashboard.json` および `.scrum/communications.json`
   を確認

**期待**:
- `dashboard.json` の `events[]` に `tool_use` か `task_completed` 行が追加
- `communications.json` の `messages[]` に `agent_spawn` (type) でエントリが
  追加 (handler は line 224 で append)

**結果記録**:
- [ ] 両ファイルに対応エントリ追加 → matcher 維持
- [ ] エントリ追加されず → setup-user.sh の matcher から該当を削除、
      dashboard-event.sh のハンドラもデッドコードとして整理

同様に `SendMessage` ツールも 1 回手動発火し、`communications.json` の
`messages[]` に該当エントリが追加されるか確認 (handler は line 251)。

## Item 3: `FileChanged` event は誰が emit するか

**背景**: `scripts/setup-user.sh:357-366` の heredoc で `FileChanged` event
が登録されている。`hooks/dashboard-event.sh:382` に handler 存在。しかし
Anthropic 公式ドキュメント上で `FileChanged` という event は明記されておらず、
発火元 (Claude Code 本体 / dashboard の watchdog Python / 他) は未確認。

**手順**:
1. `.scrum/dashboard.json` の `events[]` を初期状態 (空 or 既知の最後の event
   timestamp) で記憶
2. target project 内で **Claude Code を介さず** ファイル変更 (例: 別 terminal
   から `echo x > some-file.txt`)
3. 10 秒待機後、`.scrum/dashboard.json` を再確認

**期待**:
- 新規 event (`file_changed` type) が追加されている → FileChanged 動作
- 追加されない → FileChanged は Claude Code が **emit していない**
  ので `setup-user.sh` から削除し、`dashboard-event.sh` の handler も削除

**結果記録**:
- [ ] FileChanged event 観測 → matcher / handler 維持
- [ ] 観測されず → matcher / handler を削除する別 PR を作成

## 検証完了後の後始末

3 項目すべてに結果を記入したら、このファイルを以下のいずれかへ:
- 全て期待どおり (matcher 全部維持 + claude-fable-5 実在) → このファイルを
  削除 (`git rm`) し、メモリ `project_cleanup_audit_2026_06_12.md` に結果
  を追記
- いずれか NG → 別 PR (`fix(setup-user): drop dead matcher` 等) を切り、
  該当箇所を修正してこのファイルを削除

## 関連

- cleanup-audit Synthesis: `/tmp/claude/cleanup-audit/SYNTHESIS.md` § OD-5
- agent frontmatter overhaul: メモリ `project_agent_frontmatter_overhaul.md`
- dashboard team log: メモリ `project_dashboard_team_log.md` (SendMessage
  実機発火が未検証、と既に記載)
