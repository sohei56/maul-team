# Cleanup Audit (2026-05-08) — Phase 2+ Follow-ups

**Date:** 2026-05-08
**Status:** Phase 1 完了 (PR #42), Phase 2-4 未着手
**Source synthesis:** `/tmp/claude/cleanup-audit/SYNTHESIS.md` (注: /tmp は揮発)
**Phase 1 PR:** https://github.com/sohei56/claude-scrum-team/pull/42

## Phase 1 で消化済 (12 件)

PR #42 で landing 済。再着手不要:

- T1-A: `pre-tool-use-no-branch-ops.sh` の `git -C` / `--git-dir=` / `--work-tree=` bypass 修正 (bats 9 ケース追加)
- OD-2(a): `scrum-master.md` に safe-switch-to-main 追記
- OD-3(a): `pbi_in_backlog()` を 4 callsites で採用
- OD-7(a): `cross-review/SKILL.md` の `paths_touched` 読み出し元を `pbi-state.json` に修正
- T2c-5: `completion-gate.sh:188-193` stale "allow-list" comment 修正
- T2d-1/2/3: stale-ref 3 件
- T4-2/3: `lib/git-guards.sh` 新設 + 6 重複統合
- T4-4: `lib/queries.sh` に worktree state ヘルパー
- T4-5: `lib/errors.sh` に `assert_hex_sha`
- T4-6: `dashboard/app.py` `_format_ts_short` 抽出

## 残スコープ (5 tier × 約 38 件)

### 優先度マトリクス

| 区分 | 件数 | 性質 | 推奨 phase |
|---|---|---|---|
| OD-1 (= T1-D/E/F + T2c-8/9/10) | 6 unblock | investigation 必須 | phase 2-A |
| OD-4 (= T1-B) | 1 real bug | code change | phase 2-B |
| OD-8 | 1 | code + bats | phase 2-B |
| T2c-2 | 1 | 1-line code | phase 3 |
| OD-6 (= T2b-6) | 1 | doc only | phase 3 |
| T2b 残 7 | 7 | 概ね doc | phase 3 |
| T2c 残 (除く T2c-2) | 8 | 概ね doc | phase 3 |
| OD-5 (= T2b-8) | 1 | アーキ変更 | phase 4 |
| T3 markdown redundancy | 14 cluster ~228 行 | 純 cleanup | phase 4 |
| T5 cosmetic | 7 | bundle 用 | opportunistic |

### Phase 2-A: OD-1 hook event taxonomy investigation

**ゴール:** Claude Code docs / probe で 5 hook event の実体確認 → `docs/contracts/hook-event-catalog.md` 作成。

**対象 event** (`setup-user.sh` で登録、未検証):

- `PostCompact` (likely typo of `PreCompact`) — `session-context.sh`
- `TaskCompleted` (3ea7a3d で追加、docs に無し) — `quality-gate.sh` + `dashboard-event.sh`
- `TeammateIdle` (payload schema 未文書化) — `dashboard-event.sh:240-259`
- `Agent` matcher (canonical は `Task`) — `setup-user.sh:261` PostToolUse + `dashboard-event.sh:214-234`
- `FileChanged` (low-priority、fixture 無し) — `setup-user.sh:352-361`

**証拠:**

- `Agent` matcher は **silent fail 確定**: `.scrum/communications.json` で `agent_spawn` 0 hits
- 2026-05-07 plan の OD-3 でスモークテスト実施予定だった (未実施かは要確認)

**手順案:**

1. (a) Claude Code docs (`https://docs.claude.com/...`) で 5 event の正規名 / payload 確認
2. (b) probe session: 各 event 名を `setup-user.sh` 登録のまま、marker payload 出力する hook を当てて `.scrum/dashboard.json` の到着確認
3. 結果を `docs/contracts/hook-event-catalog.md` に記録 (各 event の `verified | renamed | dropped | repurposed` ラベル)

**output → 後続 PR:**

- 結果に基づき `setup-user.sh` の registration / matcher / hook 名を rename or drop
- `dashboard-event.sh` の case 分岐削除 (Agent → Task 相当の matcher 修正)
- `T2c-6` (dashboard-event.sh header comment) も同 PR でクリア

**所要:** 専用 1 セッション級 (調査 + 後続 PR 計 2-3 PR)

### Phase 2-B: real bug fix (OD-4 + OD-8)

#### OD-4 (T1-B) — worktree cleanup race

**現状:** `merge-pbi.sh:97-98` が成功時に `cleanup-pbi-worktree.sh` 即実行 → worktree+branch 消失 → cross-review FAIL routing (`cross-review/SKILL.md:194-204`) が「Developer が worktree で fix 上乗せ」を指示しても worktree 不在で頓挫。

**修正:** `cleanup-pbi-worktree.sh` 呼出を `merge-pbi.sh:98` から `cross-review/SKILL.md` step 11 (`status=done` と並ぶ位置) に移動。

**注意:** FAIL routing が実際に exercised された痕跡があるか `.scrum/reviews/` を要確認。理論バグの可能性。

#### OD-8 — git commit/add hook enforcement

**現状:** `developer.md:67-68` が「`commit-pbi.sh` は hook 強制」と implies、`no-branch-ops.sh` には `git commit/add` rule 無し (convention only)。

**修正:** `pre-tool-use-no-branch-ops.sh` に以下を追加:

```bash
if echo "$CMD" | grep -Eq "(^|[[:space:];|&])git${GIT_PRE_OPT}[[:space:]]+(commit|add)\b"; then
  block "git commit/add"
fi
```

T1-A で `GIT_PRE_OPT` を導入済なので追加 1 ブロックで足りる。bats: `git commit -m foo` / `git add file` / `.scrum/scripts/commit-pbi.sh ...` の 3 ケース。

**framework dev 影響:** 無し (framework の `.claude/settings.json` は no-branch-ops を register していない、CLAUDE.md `## Git workflow` 末尾参照)。

**1 PR 推奨**: OD-4 + OD-8 を同 PR (どちらも no-branch-ops / merge 周辺、related-context)。

### Phase 3: doc/cleanup batch (1 PR)

| # | 内容 | 種別 |
|---|---|---|
| OD-6 (T2b-6) | `docs/contracts/scrum-state/README.md:18` の blanket `additionalProperties:true` 主張を per-schema 列挙に書換 | doc |
| T2b-1 | `MIGRATION-scrum-state-tools.md:23` で `set-backlog-item-field.sh` field list に `priority` 追加 | doc |
| T2b-2 | `data-model.md:556` `merge_failure: object\|null` を schema (non-null) と一致させる | doc |
| T2b-3 | `data-model.md:440` `detail: string` を `string\|null` に修正 | doc |
| T2b-4 | `data-model.md:391,407,426,444` の SSOT wrapper cap 主張を hook-side 限定に修正 | doc |
| T2b-5 | `docs/contracts/scrum-state/README.md:9` `mark-pbi-merged.sh "delegates"` を「co-writes then delegates」に修正 | doc |
| T2b-7 | `sprint.schema.json:38` `sub_agents` items 型を `string` で固定 | schema 1 行 |
| T2c-1 | `data-model.md:399` `sender_role` を hyphenated lowercase に揃える | doc |
| T2c-2 | `mark-pbi-merged.sh:37` で escalation_reason clear (`del(.escalation_reason)` 追加) | code 1 行 |
| T2c-3 | `developer.md:67-68` を「convention only」に reword (OD-8 不採用時のみ。OD-8 採用ならこの行は phase 2-B に移管) | doc |
| T2c-4 | `cross-review/SKILL.md` aspect 4/5 FAIL 文言を「source PBI not reverted」と明示 | doc |
| T2c-7 | `CLAUDE.md:21` `install-subagents/` 説明を「verifies presence」に修正 | doc 1 行 |
| T5-1 | `agents/scrum-master.md:28` frontmatter コメント文言 | cosmetic |
| T5-3 | `setup-user.sh:204` permissions allowlist の `Agent` 削除 (T1-F rename と同期、phase 2-A 結果次第) | cosmetic |
| T5-4 | `scripts/scrum/append-pbi-log.sh:19,25,27,36` 内部 `PHASE` var rename | cosmetic |

### Phase 4: T3 markdown redundancy (3 wave PR)

`/tmp/cleanup-audit/SYNTHESIS.md` § Tier 3 参照。約 228 行削減見込。

- **Wave 1 (PR #1):** T3-A + T3-B reviewer-conventions extract → `docs/contracts/sub-agents.md` に統合 (8 reviewer agent + cross-review SKILL を 1 PR で touch、~70 行)
- **Wave 2 (PR #2):** T3-D, T3-F, T3-H, T3-I, T3-J (Git/handoff/sprint-review dedupe、disjoint files、~57 行)
- **Wave 3 (PR #3):** T3-C, T3-E, T3-G, T3-K, T3-L (catalog/lifecycle dedupe、disjoint files、~85 行)
- **Defer:** T3-M (Dev commands、low priority)

### Phase 4 後半 (or skip): OD-5

`dashboard.json` / `communications.json` の dual-SSOT (SSOT wrapper validate 無 cap / hook-side `append_to_json_array` cap 無 validate)。

**recommendation (b):** hook-side cap+lock helper を `lib/` に lift、両者から呼出。yields 単一 validation path + 単一 cap policy。

**defer 可否:** 実害は dashboard.json サイズ管理の二重化のみ。緊急度低。skip も可。

## ユーザー判断必要 (引き継ぎ時に再提示)

1. **OD-1 investigation を専用セッションで引き受けるか?** Yes → phase 2-A 着手。No → T1-D/E/F は当面 silent-fail 温存 (`Agent` matcher の 0 hits は確定済)。
2. **phase 2-B の粒度**: OD-4 + OD-8 を 1 PR にするか、独立にするか?
3. **phase 4 OD-5 を実施するか skip するか?** 実害低、defer 可。

## 着手手順 (次セッション cold-start)

1. main 最新を pull (`origin/main` に PR #42 が merge 済を確認)
2. 本ファイル + `/tmp/claude/cleanup-audit/SYNTHESIS.md` (残存していれば) を読む
3. ユーザーに上記 3 質問を提示
4. phase 選択 → branch 切る (推奨命名: `chore/cleanup-audit-phase-{2a|2b|3|4-wave-N}`)

## 関連ファイル

- 本セッションの SYNTHESIS: `/tmp/claude/cleanup-audit/SYNTHESIS.md` (揮発)
- 前 round plan (2026-05-07、別審査): `docs/superpowers/plans/2026-05-07-cleanup-audit.md`
- Phase 1 PR: #42 (commit ff0a4b2)
- 関連 memory: `~/.claude/projects/-Users-inouesouhei-work-claude-scrum-team/memory/MEMORY.md`
