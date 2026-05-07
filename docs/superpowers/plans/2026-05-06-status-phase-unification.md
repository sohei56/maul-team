# Status/Phase Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `backlog.json.items[].status` (6値) と `pbi-state.json.phase` (10値) を 12値 flat Status enum に統一し、二元管理由来の drift バグを構造的に排除する。

**Architecture:** Status を **唯一の SSOT フィールド** に昇格、`phase` 削除。actor 分離 (`in_progress_*` = Developer 管理、他 = SM 管理)。Per-PBI 即時 merge は維持、Sprint 末 cross_review も既存挙動踏襲 (リネームのみ)。

**Tech Stack:** Bash 3.2+, JSON Schema draft-07, jq, bats, Python (Textual dashboard)。

---

## Confirmed Status enum

```
SM管理 (7):  draft, refined, blocked, awaiting_cross_review, cross_review, escalated, done
Dev管理 (5): in_progress_design, in_progress_impl, in_progress_pbi_review,
             in_progress_ut_run, in_progress_merge
```

## Confirmed Transition graph

```
[SM]  draft → refined
                ↓ (Sprint planning assigns Developer)
[Dev] in_progress_design
        ↓ design pass (codex-design-reviewer)
[Dev] in_progress_impl ←──────────┐
        ↓                          │ FAIL
[Dev] in_progress_pbi_review ──────┤  (codex-impl-reviewer + codex-ut-reviewer)
        ↓ PASS                     │
[Dev] in_progress_ut_run ──────────┘ FAIL  (real test execution + coverage gate)
        ↓ PASS
[Dev] in_progress_merge            (Developer signals "ready for merge")
        ↓ SM picks up, runs merge-pbi.sh
        ↓ merge PASS
[SM]  awaiting_cross_review        (merged into main, Sprint 末まで待機)
        ↓ Sprint 末 SM が cross-review skill 起動
[SM]  cross_review ── FAIL → [Dev] in_progress_impl  (Developer fixes on top of merged code)
        ↓ PASS
[SM]  done

  any [Dev] in_progress_* → [SM] escalated  (Developer 発火: termination-gate trip)
  in_progress_merge       → [SM] escalated  (SM merge 失敗時)
  [SM] escalated → [Dev] in_progress_design  (SM retry; round counters reset)
  [SM] escalated → [SM] blocked              (SM hold/human-escalate)
  [SM] blocked   → [Dev] in_progress_design  (外部要因解消後の再開)
```

## Renaming map (current → new)

| 旧 (phase or status) | 新 status |
|---|---|
| `status: draft` | `draft` |
| `status: refined` | `refined` |
| `status: blocked` | `blocked` |
| `status: in_progress` (phase: design) | `in_progress_design` |
| `status: in_progress` (phase: impl_ut) | `in_progress_impl` (impl_ut の名残はリネーム; pbi_review/ut_run に分割される) |
| `status: review` (phase: complete) | `in_progress_pbi_review` |
| `status: review` (phase: ready_to_merge) | `in_progress_merge` |
| `status: review` (phase: merged) | `awaiting_cross_review` |
| `status: review` (phase: merge_conflict / merge_artifact_missing / merge_regression) | `escalated` (`merge_failure.kind` で詳細保持) |
| `status: review` (phase: review_complete) | (廃止: cross_review PASS は直接 `done`) |
| `status: done` (phase: review_complete) | `done` |
| `status: blocked` (phase: escalated) | `escalated` (新規分離) |

**注**: `in_progress_pbi_review` と `in_progress_ut_run` は旧 `phase: impl_ut` の細分化。旧 schema で両者を区別する情報は無いため、移行時は `impl_ut` を一律 `in_progress_impl` に寄せる (loss-less migration; 実行中の PBI は次サイクルで自然に新粒度に乗る)。

---

## Architectural Decisions

1. **`phase` フィールドの完全削除**: `pbi-state.schema.json` から `phase` 削除。`escalation_reason`, rounds, design_status / impl_status / ut_status / coverage_status, merge_failure 等 PBI Pipeline 内部状態は残す。
2. **`derive.sh` の削除**: phase→status 写像は不要 (status が SSOT)。
3. **`update-backlog-status.sh` の責務拡大**: 12 値全て受付。`is_post_pipeline_status` の gate は削除 (代わりに transition 妥当性チェック検討は将来課題)。
4. **`update-pbi-state.sh` から `phase` 削除**: 他フィールドの setter 機能は維持。
5. **新規 `cross_review_started_at` フィールド**: `awaiting_cross_review` と `cross_review` の区別 (status 値は別)。実装上は両 status を別エントリで持つので `started_at` は不要かも → **保留** (PBI-A で再判断)。
6. **`merge_failure.kind` 情報の保持**: `escalated` に潰した後も `pbi-state.json.merge_failure.kind` で詳細を残す。escalation_reason に新規 enum `merge_conflict`, `merge_artifact_missing`, `merge_regression` を追加。
7. **既存 `.scrum/` データ migration**: 別スクリプトで一括変換。schema 変更後の旧 fixture も bats で v1→v2 変換テスト。
8. **`sprint.json.developers[].current_pbi_phase` の処理**: 削除する。新しく `current_pbi_status` を追加するか、backlog から都度引くか → backlog 引きで統一 (重複情報削減)。

---

## File-level scope inventory

### Schema (3 files + 1 alt)
- `docs/contracts/scrum-state/backlog.schema.json` — items[].status enum 12値化
- `docs/contracts/scrum-state/pbi-state.schema.json` — phase 削除、escalation_reason に merge 系3値追加
- `docs/contracts/scrum-state/sprint.schema.json` — developers[].current_pbi_phase 削除
- `docs/contracts/state-schemas.json` — 上記との整合確認 (alt schema; 内容次第で更新)

### Test fixtures
- `tests/fixtures/valid-backlog.json`
- `tests/fixtures/valid-sprint.json`
- 関連 invalid fixtures があれば追加更新

### Scripts (in `scripts/scrum/`, deployed to `.scrum/scripts/` via setup-user.sh)
- `update-backlog-status.sh` — 12値受付、gate 削除
- `update-pbi-state.sh` — phase キー削除、escalation_reason の新値受付
- `mark-pbi-ready-to-merge.sh` — phase 設定をやめ、status 設定に切替
- `mark-pbi-merged.sh` — phase 設定をやめ、status 設定に切替
- `mark-pbi-merge-failure.sh` — phase 設定をやめ、escalation 経路へ
- `merge-pbi.sh` — 内部呼び出しを status ベースに
- `cleanup-pbi-worktree.sh` — phase 参照箇所更新
- `migrate-legacy.sh` — 旧 schema migration ロジック更新
- `add-backlog-item.sh` — 新規 PBI の初期 status (`draft`) 維持、特に変更なしか確認
- `lib/derive.sh` — **削除** (一部 helper を残すなら別ファイル化)

### Hooks
- `pre-tool-use-scrum-state-guard.sh`
- `completion-gate.sh`
- `quality-gate.sh`
- `phase-gate.sh` — リネーム検討 (`status-gate.sh`?)
- `dashboard-event.sh`
- `session-context.sh`
- `pre-tool-use-no-branch-ops.sh` — branch op gating ロジックは status 非依存と思われる、要確認

### Skills (`skills/`)
- `pbi-pipeline/SKILL.md` + `references/*.md` (state-management, phase1-design, phase2-impl-ut, sub-agent-prompts, termination-gates, coverage-gate, catalog-contention)
- `cross-review/SKILL.md`
- `pbi-merge/SKILL.md`
- `pbi-escalation-handler/SKILL.md`
- `sprint-planning/SKILL.md`
- `sprint-review/SKILL.md`
- `spawn-teammates/SKILL.md`
- `backlog-refinement/SKILL.md`
- `retrospective/SKILL.md`
- `integration-sprint/SKILL.md`
- `scaffold-design-spec/SKILL.md`
- `smoke-test/SKILL.md`
- `requirements-sprint/SKILL.md`

### Agents (`agents/`)
- `developer.md`
- `scrum-master.md`
- `pbi-designer.md`
- `pbi-implementer.md`
- `pbi-ut-author.md`
- `code-reviewer.md`
- `security-reviewer.md`
- `codex-design-reviewer.md`, `codex-impl-reviewer.md`, `codex-ut-reviewer.md`, `codex-code-reviewer.md`

### Dashboard
- `dashboard/app.py` — backlog.json から status 読み出し、phase 読み出し撤去

### Top-level docs
- `CLAUDE.md` — Status flow / Phase flow セクションを 12値統合版に書き換え
- `docs/architecture.md`
- `docs/data-model.md`
- `docs/requirements.md`
- `docs/MIGRATION-scrum-state-tools.md` — v2 移行手順追記
- `docs/contracts/agent-interfaces.md`

### Tests
- `tests/unit/state-schema.bats`
- `tests/integration/script-compose.bats`
- 新規: `tests/integration/migration-v1-to-v2.bats`
- 新規: `tests/integration/escalation-smoke.bats`

---

## PBI 分割 (Sub-agent dispatch units)

実装は本リポジトリの PBI Pipeline 自体を**使わない** (meta-project)。Sub-agent に直接ディスパッチ。

```
PBI-A (Schema)
  ↓ blocks
  ├─→ PBI-B (Scripts)
  ├─→ PBI-C (Hooks)
  └─→ PBI-I (Escalation smoke test) ─── (independent)
            ↓
       PBI-B blocks
       ├─→ PBI-D (Skills text)
       ├─→ PBI-E (Agents text)
       ├─→ PBI-F (Dashboard)
       └─→ PBI-G (Migration script)
                  ↓ all of D,E,F,G complete
                  └─→ PBI-H (Top-level docs)
```

**並列実行可能群**:
- Round 1 (A 完了後): B, C, I 並列
- Round 2 (B 完了後): D, E, F, G 並列
- Round 3: H 単独

---

## PBI-A: Schema migration

**Files:**
- Modify: `docs/contracts/scrum-state/backlog.schema.json`
- Modify: `docs/contracts/scrum-state/pbi-state.schema.json`
- Modify: `docs/contracts/scrum-state/sprint.schema.json`
- Verify/Update: `docs/contracts/state-schemas.json`
- Modify: `tests/fixtures/valid-backlog.json`
- Modify: `tests/fixtures/valid-sprint.json`
- Modify: `tests/unit/state-schema.bats`

### Steps

- [ ] **Step 1: backlog.schema.json — items[].status enum 拡張**

`status` の enum を以下に置換:
```json
"status": {
  "enum": [
    "draft", "refined", "blocked",
    "in_progress_design", "in_progress_impl", "in_progress_pbi_review",
    "in_progress_ut_run", "in_progress_merge",
    "awaiting_cross_review", "cross_review",
    "escalated", "done"
  ]
}
```

`pipeline_summary.outcome` は `["complete", "escalated"]` のまま (内部記録、status とは別概念)。

- [ ] **Step 2: pbi-state.schema.json — phase 削除、escalation_reason 拡張**

`phase` プロパティを完全削除 (required 配列からも削除)。`escalation_reason` の enum に 3値追加:

```json
"escalation_reason": {
  "type": ["string", "null"],
  "enum": [
    null,
    "stagnation", "divergence", "max_rounds", "budget_exhausted",
    "requirements_unclear", "coverage_tool_error", "coverage_tool_unavailable",
    "catalog_lock_timeout",
    "merge_conflict", "merge_artifact_missing", "merge_regression"
  ]
}
```

`required` から `phase` を削除し、`["pbi_id", "started_at", "updated_at"]` のみ残す。

- [ ] **Step 3: sprint.schema.json — developers[].current_pbi_phase 削除**

`current_pbi_phase` プロパティを削除。`required` には元々入っていないので変更不要。

- [ ] **Step 4: state-schemas.json 整合確認**

ファイル内容を読んで、3 schema との整合性を確認。`status` enum 列挙が含まれているなら同様に更新。

- [ ] **Step 5: fixtures 更新**

`tests/fixtures/valid-backlog.json` と `tests/fixtures/valid-sprint.json` の status / phase 値を新値に。`developer.current_pbi_phase` を含む fixture から該当フィールド削除。

- [ ] **Step 6: bats 単体テスト更新**

`tests/unit/state-schema.bats` で:
- 旧 enum 値 (in_progress, review, design, impl_ut 等) のアサーションを 12値新 enum に置換
- 不正値テストは新 enum 外の値 (例: `"invalid_status"`, 旧 `"in_progress"`) で fail を期待する形に
- phase 関連テストは削除 (schema から phase 自体が無いので)

- [ ] **Step 7: 検証**

```bash
bats tests/unit/state-schema.bats
shellcheck scripts/scrum/*.sh hooks/*.sh
```
全 PASS を確認。

- [ ] **Step 8: Commit**

```bash
git add docs/contracts/scrum-state/ docs/contracts/state-schemas.json \
        tests/fixtures/valid-backlog.json tests/fixtures/valid-sprint.json \
        tests/unit/state-schema.bats
git commit -m "feat(schema): unify status/phase into 12-value status enum"
```

### Acceptance criteria
- 3 schema ファイルで新 enum/フィールド変更が反映
- fixture が新 schema にバリデーション PASS
- bats 単体テスト緑

---

## PBI-B: Script wrappers refactor

**Depends on:** PBI-A

**Files:**
- Modify: `scripts/scrum/update-backlog-status.sh`
- Modify: `scripts/scrum/update-pbi-state.sh`
- Modify: `scripts/scrum/mark-pbi-ready-to-merge.sh`
- Modify: `scripts/scrum/mark-pbi-merged.sh`
- Modify: `scripts/scrum/mark-pbi-merge-failure.sh`
- Modify: `scripts/scrum/merge-pbi.sh`
- Modify: `scripts/scrum/cleanup-pbi-worktree.sh`
- Modify: `scripts/scrum/migrate-legacy.sh`
- Delete: `scripts/scrum/lib/derive.sh`
- Modify: `tests/integration/script-compose.bats`

### Steps

- [ ] **Step 1: update-backlog-status.sh — 12値受付化**

`case "$STATUS"` の enum を 12値に拡張。`is_post_pipeline_status` gate と `SCRUM_ALLOW_POST_PIPELINE_STATUS` escape hatch を**削除** (理由: status が SSOT。pipeline 系 status も普通に書く)。`derive.sh` の source 行も削除。コメント書き換え (旧 "Status flow split" → 新 "12-value status SSOT")。

- [ ] **Step 2: update-pbi-state.sh — phase キー削除、escalation_reason 新値**

- `phase` を case パターンから削除
- `phase` 関連の `NEW_PHASE` 変数と末尾の backlog projection ブロック (lines 151-165) を全削除
- `derive.sh` source 行と comment 削除
- `escalation_reason` の case 内 enum に `merge_conflict|merge_artifact_missing|merge_regression` 追加
- usage コメント (先頭 doc) を更新: writable fields 一覧から `phase` 行削除

- [ ] **Step 3: mark-pbi-ready-to-merge.sh — status 設定に切替**

旧: `update-pbi-state.sh "$PBI" phase ready_to_merge ready_at "..."` 等を呼んでいる
新: `update-pbi-state.sh "$PBI" ready_at "..."` (phase 引数除去) + `update-backlog-status.sh "$PBI" in_progress_merge`

該当スクリプトの先頭 doc も更新。

- [ ] **Step 4: mark-pbi-merged.sh — status 設定に切替**

旧: `phase merged merged_sha ... merged_at ...`
新: `merged_sha ... merged_at ...` + `update-backlog-status.sh "$PBI" awaiting_cross_review`

- [ ] **Step 5: mark-pbi-merge-failure.sh — escalation 経路へ**

旧: `phase merge_conflict` 等を設定
新: `update-pbi-state.sh "$PBI" escalation_reason <kind>` + `merge_failure.kind` (既存) を設定 + `update-backlog-status.sh "$PBI" escalated`

- [ ] **Step 6: merge-pbi.sh — 呼び出し箇所更新**

`mark-pbi-*` 系の呼び出しは Step 3-5 で間接的に変わる。`merge-pbi.sh` 自身が phase を直接書いていれば status に切替。冒頭 doc も更新。

- [ ] **Step 7: cleanup-pbi-worktree.sh — phase 参照削除**

`phase` を読んで判定している箇所があれば status ベースに置換。`escalated` または `done` で worktree クリーンアップする等の条件は要確認・修正。

- [ ] **Step 8: migrate-legacy.sh — 新 status enum 出力**

旧 `.scrum/` データを新 status に変換するロジックを追加。具体的には:
- 旧 `status=in_progress` + `phase=design` → `in_progress_design`
- 旧 `status=in_progress` + `phase=impl_ut` → `in_progress_impl`
- 旧 `status=review` + `phase=complete` → `in_progress_pbi_review`
- 旧 `status=review` + `phase=ready_to_merge` → `in_progress_merge`
- 旧 `status=review` + `phase=merged` → `awaiting_cross_review`
- 旧 `status=review` + `phase=merge_*` → `escalated`
- 旧 `status=review` + `phase=review_complete` → `done`
- 旧 `status=blocked` + `phase=escalated` → `escalated`
- 旧 `status=draft|refined|blocked|done` (phase なし) → 同名 (refined/blocked/done) または draft

- [ ] **Step 9: lib/derive.sh 削除**

```bash
git rm scripts/scrum/lib/derive.sh
```

他に source している箇所が残っていないか grep で確認。

- [ ] **Step 10: tests/integration/script-compose.bats 更新**

phase 経由の status 書き込みテストを、status 直接書き込みテストに書き換え。新シナリオ:
- update-backlog-status.sh で 12値全てに OK
- update-pbi-state.sh で phase キー指定 → fail (引数不正)
- mark-pbi-ready-to-merge.sh → status が `in_progress_merge` になる
- mark-pbi-merged.sh → status が `awaiting_cross_review` になる
- mark-pbi-merge-failure.sh → status が `escalated` になる + `merge_failure.kind` セット

- [ ] **Step 11: 検証**

```bash
bats tests/unit/ tests/integration/
shellcheck scripts/scrum/*.sh scripts/scrum/lib/*.sh
```

- [ ] **Step 12: Commit**

```bash
git add scripts/scrum/ tests/integration/script-compose.bats
git rm scripts/scrum/lib/derive.sh
git commit -m "refactor(scripts): drop phase field, write status directly via wrappers"
```

### Acceptance criteria
- `derive.sh` 削除、source 残存ゼロ
- 全 wrapper が status 直接書き込み
- bats 緑、shellcheck 緑

---

## PBI-C: Hooks update

**Depends on:** PBI-A (schema enum)

**Files:**
- Modify: `hooks/pre-tool-use-scrum-state-guard.sh`
- Modify: `hooks/completion-gate.sh`
- Modify: `hooks/quality-gate.sh`
- Rename + Modify: `hooks/phase-gate.sh` → `hooks/status-gate.sh`
- Modify: `hooks/dashboard-event.sh`
- Modify: `hooks/session-context.sh`
- Verify: `hooks/pre-tool-use-no-branch-ops.sh`
- Modify: `hooks/lib/*.sh` (any phase references)
- Update: `.claude/settings.json` (hook 登録名が変わる場合)

### Steps

- [ ] **Step 1: pre-tool-use-scrum-state-guard.sh**

phase 直書き禁止の case ブランチを確認。phase は schema から消えたので、blacklist から `phase` 関連を削除。status 直書きの guard は wrapper 経由を強制する形を維持。

- [ ] **Step 2: completion-gate.sh / quality-gate.sh**

phase を読んで gate 判定している箇所があれば status 読みに切替。`merged` phase チェック → `awaiting_cross_review` または `done` status チェック。`review_complete` チェック → `done` status チェック。

- [ ] **Step 3: phase-gate.sh → status-gate.sh リネーム**

```bash
git mv hooks/phase-gate.sh hooks/status-gate.sh
```
内部の phase 参照を status に置換。`.claude/settings.json` で hook が `phase-gate.sh` 名で登録されていれば登録名も更新。

- [ ] **Step 4: dashboard-event.sh / session-context.sh**

phase 読み出し箇所を status 読みに置換。dashboard event 種別 `phase_transition` は `status_transition` にリネーム検討 (dashboard.schema.json と協調)。

- [ ] **Step 5: hooks/lib/*.sh**

phase 関連の helper を grep。あれば status ベースに書き換え。

- [ ] **Step 6: pre-tool-use-no-branch-ops.sh 確認**

branch ops gating は status / phase 非依存のはず。一応 grep。phase 言及があれば status に。

- [ ] **Step 7: .claude/settings.json**

hook 登録の path が変わったら更新。

- [ ] **Step 8: 検証**

```bash
shellcheck hooks/*.sh hooks/lib/*.sh
bats tests/unit/ tests/lint/
```

- [ ] **Step 9: Commit**

```bash
git add hooks/ .claude/settings.json
git commit -m "refactor(hooks): switch from phase to status reads, rename phase-gate"
```

### Acceptance criteria
- 全 hook で phase 参照ゼロ (grep `phase` で 0件、コメント以外)
- shellcheck 緑

---

## PBI-D: Skills text update

**Depends on:** PBI-A, PBI-B (accurate command examples)

**Files:** (skills/*/SKILL.md および references)
- `skills/pbi-pipeline/SKILL.md`
- `skills/pbi-pipeline/references/state-management.md`
- `skills/pbi-pipeline/references/phase1-design.md`
- `skills/pbi-pipeline/references/phase2-impl-ut.md`
- `skills/pbi-pipeline/references/sub-agent-prompts.md`
- `skills/pbi-pipeline/references/termination-gates.md`
- `skills/pbi-pipeline/references/coverage-gate.md`
- `skills/pbi-pipeline/references/catalog-contention.md`
- `skills/cross-review/SKILL.md`
- `skills/pbi-merge/SKILL.md`
- `skills/pbi-escalation-handler/SKILL.md`
- `skills/sprint-planning/SKILL.md`
- `skills/sprint-review/SKILL.md`
- `skills/spawn-teammates/SKILL.md`
- `skills/backlog-refinement/SKILL.md`
- `skills/retrospective/SKILL.md`
- `skills/integration-sprint/SKILL.md`
- `skills/scaffold-design-spec/SKILL.md`
- `skills/smoke-test/SKILL.md`
- `skills/requirements-sprint/SKILL.md`

### Steps

- [ ] **Step 1: phase 言及の grep**

```bash
grep -rn "phase" skills/ | tee /tmp/skills-phase-refs.txt
grep -rn "in_progress\|review_complete\|impl_ut\|ready_to_merge" skills/ | tee /tmp/skills-status-refs.txt
```

- [ ] **Step 2: 機械置換 (sed) 一次パス**

代表的な置換例 (各 skill ファイル個別に確認):
- `phase: design` → `status: in_progress_design`
- `phase: impl_ut` → `status: in_progress_impl` (+ pbi_review/ut_run の段階分割を文書化)
- `phase: complete` → `status: in_progress_pbi_review`
- `phase: ready_to_merge` → `status: in_progress_merge`
- `phase: merged` → `status: awaiting_cross_review`
- `phase: review` → `status: cross_review`
- `phase: review_complete` → `status: done`
- `phase: escalated` → `status: escalated`
- `update-pbi-state.sh "$PBI_ID" phase X` → `update-backlog-status.sh "$PBI_ID" Y`

- [ ] **Step 3: pbi-pipeline/SKILL.md と references 重点リライト**

state-management.md は phase の説明が中心 → status へ全面書き換え。phase1-design.md / phase2-impl-ut.md は段階説明を新 status 名に統一。new flow (impl ↔ pbi_review ↔ ut_run の戻りループ) を遷移グラフで明示。termination-gates.md は escalation 発火時の status 遷移を明記。

- [ ] **Step 4: cross-review/SKILL.md**

skill 名は維持。doc 内で:
- "Sprint-end cross-cutting quality gate" 表現は維持
- precondition: `pbi/<id>/state.json.phase ∈ {merged, escalated}` → `backlog.json.items[].status ∈ {awaiting_cross_review, escalated}`
- 出力: `phase: complete → review_complete` → `status: cross_review → done`
- 一時的に `cross_review` 状態をセット、PASS で `done`
- FAIL 経路: `status: in_progress_impl` に戻し Developer 修正

- [ ] **Step 5: pbi-merge/SKILL.md**

merge 完了時 status を `awaiting_cross_review` にセットすることを明記。失敗時 `escalated` + `merge_failure` 詳細を記録。

- [ ] **Step 6: pbi-escalation-handler/SKILL.md**

Response Matrix の retry / hold / human-escalate 動作を新 status 値で記述。retry 時 `update-backlog-status.sh "$PBI" in_progress_design` + state.json の round counters / `*_status` リセット。

- [ ] **Step 7: 残り skill (sprint-planning, sprint-review, etc.) は機械置換 + 軽い手動レビュー**

主に status 値の参照箇所のみ。

- [ ] **Step 8: 検証**

```bash
grep -rn "\bphase\b" skills/ | grep -v "^skills/.*\.md:.*Phase" | grep -v "design phase\|impl phase"
# (上記で意味的に "phase" として残る箇所が無いことを確認)
bats tests/lint/  # markdown lint があれば
```

- [ ] **Step 9: Commit**

```bash
git add skills/
git commit -m "docs(skills): update terminology from phase to 12-value status"
```

### Acceptance criteria
- 全 skill から `phase` という pipeline 用語が消える (一般語 "phase" は残ってよい)
- 全 status 値が 12値新 enum に準拠
- pbi-pipeline references が新 flow を反映

---

## PBI-E: Agents text update

**Depends on:** PBI-A, PBI-B

**Files:**
- `agents/developer.md`
- `agents/scrum-master.md`
- `agents/pbi-designer.md`
- `agents/pbi-implementer.md`
- `agents/pbi-ut-author.md`
- `agents/code-reviewer.md`
- `agents/security-reviewer.md`
- `agents/codex-design-reviewer.md`
- `agents/codex-impl-reviewer.md`
- `agents/codex-ut-reviewer.md`
- `agents/codex-code-reviewer.md`

### Steps

- [ ] **Step 1: grep で phase / 旧 status 言及確認**

```bash
grep -rn "phase\|in_progress\|review_complete\|impl_ut\|ready_to_merge" agents/
```

- [ ] **Step 2: developer.md 重点書き換え**

Developer の責務記述で:
- 担当 status 範囲を `in_progress_design / impl / pbi_review / ut_run / merge` と明示
- 各 status 遷移時に `update-backlog-status.sh` 呼び出しを行うことを記載
- `update-pbi-state.sh` は内部 round/status (`design_status` 等) のみで使い、status を間接的に更新する責務は無くなった旨

- [ ] **Step 3: scrum-master.md 重点書き換え**

SM の責務記述で:
- 担当 status 範囲を `draft / refined / blocked / awaiting_cross_review / cross_review / escalated / done` と明示
- `awaiting_cross_review` から `cross_review` への遷移は cross-review skill 起動時
- `escalated` 受信時は pbi-escalation-handler skill 起動

- [ ] **Step 4: 残り agent 文書の機械置換 + 手動レビュー**

特に codex-* reviewer は state を直接触らないので、参照のみ更新。

- [ ] **Step 5: 検証**

```bash
grep -rn "\bphase\b" agents/ | grep -vE "design phase|impl phase|implementation phase"
```

- [ ] **Step 6: Commit**

```bash
git add agents/
git commit -m "docs(agents): update terminology from phase to 12-value status"
```

### Acceptance criteria
- developer.md / scrum-master.md で actor 別 status 責務が明示
- 全 agent 文書で旧 phase 用語残存ゼロ

---

## PBI-F: Dashboard update

**Depends on:** PBI-A, PBI-B

**Files:**
- Modify: `dashboard/app.py`
- Modify: `docs/contracts/scrum-state/dashboard.schema.json` (`phase_transition` event 種別等)
- Modify: `docs/contracts/scrum-state/communications.schema.json` (`phase_transition` event)

### Steps

- [ ] **Step 1: dashboard/app.py の phase 参照箇所特定**

```bash
grep -n "phase\|in_progress\|review_complete" dashboard/app.py
```

- [ ] **Step 2: 読み出し先を backlog.json に統一**

PBI 状態は `backlog.json.items[].status` のみから読む。`pbi-state.json.phase` 参照を全削除。表示用の status ラベル (例: 日本語化 / 短縮形) は dict マッピングで定義。12値分のラベル定義必要。

- [ ] **Step 3: 12値分の表示色/アイコン定義**

actor (Dev / SM) で配色分けする等。例:
- SM管理 (draft, refined, blocked, awaiting_cross_review, cross_review, escalated, done) → 緑系
- Dev管理 (in_progress_*) → 青系

- [ ] **Step 4: dashboard.schema.json / communications.schema.json**

`phase_transition` event 種別を `status_transition` にリネーム。`phase_from / phase_to` フィールドを `status_from / status_to` に。`phase` プロパティ (dashboard.schema.json line 49 等) も `status` に。

- [ ] **Step 5: 関連スクリプト更新**

dashboard event を吐く側 (`scripts/scrum/append-dashboard-event.sh` など) が phase 参照していれば status に置換。

- [ ] **Step 6: 検証**

```bash
ruff check dashboard/
ruff format dashboard/
# 手動: dashboard/app.py を起動して PBI 一覧表示が正常か確認
```

- [ ] **Step 7: Commit**

```bash
git add dashboard/ docs/contracts/scrum-state/dashboard.schema.json \
        docs/contracts/scrum-state/communications.schema.json \
        scripts/scrum/append-dashboard-event.sh
git commit -m "refactor(dashboard): read 12-value status, drop phase reads"
```

### Acceptance criteria
- dashboard/app.py で phase 読み出しゼロ
- dashboard 起動して全 12値 status が正しく表示
- ruff 緑

---

## PBI-G: Existing project migration script

**Depends on:** PBI-A, PBI-B

**Files:**
- Create: `scripts/migrate-status-v2.sh`
- Create: `tests/integration/migration-v1-to-v2.bats`
- Create: `tests/fixtures/legacy-v1-backlog.json` (旧形式 fixture)
- Create: `tests/fixtures/legacy-v1-pbi-state.json`

### Steps

- [ ] **Step 1: migrate-status-v2.sh の骨格**

入力: `.scrum/backlog.json` + `.scrum/pbi/<id>/state.json` (旧形式)
出力: 新 schema 準拠の `backlog.json` + `pbi-state.json` (phase なし、escalation_reason 拡張)
処理:
1. 旧 backlog の各 PBI について、対応する pbi-state.json があれば phase を読む
2. 写像表 (Renaming map 参照) で新 status を決定
3. atomic_write で新 schema 準拠形式に上書き
4. pbi-state.json から phase キーを削除
5. backup として `.scrum/backups/migrate-v2-<timestamp>/` にコピー保存

- [ ] **Step 2: 写像写像表をスクリプトに実装**

```bash
derive_v2_status() {
  local old_status="$1"
  local old_phase="${2:-}"
  case "$old_status" in
    draft|refined|done) echo "$old_status" ;;
    blocked)
      [ "$old_phase" = "escalated" ] && echo "escalated" || echo "blocked"
      ;;
    in_progress)
      case "$old_phase" in
        design) echo "in_progress_design" ;;
        impl_ut) echo "in_progress_impl" ;;
        *) echo "in_progress_design" ;;  # safe default
      esac
      ;;
    review)
      case "$old_phase" in
        complete) echo "in_progress_pbi_review" ;;
        ready_to_merge) echo "in_progress_merge" ;;
        merged) echo "awaiting_cross_review" ;;
        merge_conflict|merge_artifact_missing|merge_regression) echo "escalated" ;;
        review_complete) echo "done" ;;
        *) echo "awaiting_cross_review" ;;  # safe default
      esac
      ;;
    *) return 1 ;;
  esac
}
```

非自明ケース (status=review に対応 phase 不明) はエラー停止 + ログ出力で人手確認を促す方が安全 → `*) fail` にする版を採用。

- [ ] **Step 3: bats テスト**

`tests/integration/migration-v1-to-v2.bats`:
- 旧 fixture を一時 .scrum/ に展開
- migrate-status-v2.sh 実行
- 新 schema バリデーション PASS
- 個別 PBI の status が期待値 (写像表通り) になっていることをアサート

- [ ] **Step 4: 旧 fixture 作成**

`tests/fixtures/legacy-v1-backlog.json`: 旧 6値 status + `pipeline_summary` 等の旧構造
`tests/fixtures/legacy-v1-pbi-state.json`: phase 入りの state

- [ ] **Step 5: 検証**

```bash
bats tests/integration/migration-v1-to-v2.bats
shellcheck scripts/migrate-status-v2.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/migrate-status-v2.sh tests/integration/migration-v1-to-v2.bats \
        tests/fixtures/legacy-v1-*.json
git commit -m "feat(migration): add v1→v2 status migration script"
```

### Acceptance criteria
- migrate-status-v2.sh 実行後、新 schema バリデーション PASS
- 写像表全パターンを bats でカバー

---

## PBI-H: Top-level docs

**Depends on:** PBI-A, PBI-B, PBI-C, PBI-D, PBI-E, PBI-F, PBI-G

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture.md`
- Modify: `docs/data-model.md`
- Modify: `docs/requirements.md`
- Modify: `docs/MIGRATION-scrum-state-tools.md`
- Modify: `docs/contracts/agent-interfaces.md`

### Steps

- [ ] **Step 1: CLAUDE.md "Key Conventions" 更新**

旧:
```
- PBI status flow: `draft → refined → in_progress → review → done | blocked`
```
新:
```
- PBI status flow (12値, actor-split):
  - SM管理: `draft → refined → blocked → awaiting_cross_review → cross_review → escalated → done`
  - Developer管理: `in_progress_design → in_progress_impl ⇄ in_progress_pbi_review ⇄ in_progress_ut_run → in_progress_merge`
- Phase concept removed; status is sole SSOT.
```

- [ ] **Step 2: CLAUDE.md "State management" セクション更新**

旧 phase 言及 (worktree/merge 関連) を status 言及に。`pbi-state.json` の説明から phase を削除。

- [ ] **Step 3: docs/architecture.md / data-model.md / requirements.md**

phase 概念を全て status に。新 12値 enum と遷移グラフ図を追加。

- [ ] **Step 4: docs/MIGRATION-scrum-state-tools.md**

v1 → v2 migration セクション追加。`migrate-status-v2.sh` の使い方、写像表、注意点 (例: 並行実行中のプロジェクトは migration 前に PBI Pipeline 停止) を記載。

- [ ] **Step 5: docs/contracts/agent-interfaces.md**

agent 間 communication で status を渡す箇所のスキーマを 12値新 enum に。

- [ ] **Step 6: 検証**

```bash
grep -rn "\bphase\b" docs/ CLAUDE.md | grep -vE "design phase|impl phase|impl/UT phase"
# 残ってよい一般語 ("design phase" 等) 以外の phase 参照ゼロ
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/
git commit -m "docs: update top-level docs for 12-value status enum"
```

### Acceptance criteria
- CLAUDE.md の Key Conventions / State management が新 enum 準拠
- 全 docs で phase 概念削除、新遷移グラフ反映

---

## PBI-I: Escalation smoke test (independent)

**Depends on:** PBI-A (only schema)

**Files:**
- Create: `tests/integration/escalation-smoke.bats`

### Steps

- [ ] **Step 1: テスト設計**

3 シナリオ最小:
1. Stagnation 発火: 同じ finding signature を 2 Round 連続発生させ、Developer が `update-backlog-status.sh "$PBI" escalated` + `escalation_reason stagnation` をセットすることを検証
2. Max rounds 発火: Round 5 到達で escalated + `max_rounds`
3. Merge failure: merge-pbi.sh 失敗 → status = escalated + escalation_reason = merge_conflict 等

- [ ] **Step 2: 実装**

`bats` で `.scrum/` を一時ディレクトリに作り、PBI Pipeline は実行せず **状態遷移を直接スクリプトで再現** してテストする (本物の Pipeline 動作は対象外)。

- [ ] **Step 3: 検証**

```bash
bats tests/integration/escalation-smoke.bats
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/escalation-smoke.bats
git commit -m "test: add escalation status transition smoke tests"
```

### Acceptance criteria
- 3 シナリオ全 PASS

**Note**: 本 PBI は本来の escalation 発火検証 (Pipeline 動作中) ではなく、status 遷移の正しさのみ検証する。Pipeline 動作中の発火検証は別途 PBI で扱う (本プランのスコープ外)。

---

## Self-Review

**Spec coverage**:
- 12値 status enum 統合 → PBI-A
- phase 削除 → PBI-A, PBI-B
- actor 分離 (Dev/SM) → PBI-D, PBI-E (文書化のみ; 技術強制は将来課題)
- 既存 cross_review 挙動維持 (Sprint 末バッチ) → PBI-D
- per-PBI 即時 merge 維持 → PBI-B, PBI-D
- 既存プロジェクトの migration → PBI-G
- escalation 経路の status 化 → PBI-B, PBI-D

**Placeholder scan**: 抽象指示 ("適切に処理" 等) は無し。grep / sed パターンは具体例付き。

**Type consistency**: enum 12値の表記は全 PBI で統一 (`in_progress_*`, `awaiting_cross_review`, `cross_review`, `escalated`, `done`, `draft`, `refined`, `blocked`)。

**Open issue (実装中に判断する)**: 
- 状態 `awaiting_cross_review` と `cross_review` を別 status にするか、`cross_review_started_at` timestamp で区別するか → **両 status 値を別エントリで持つ採用** (Plan 通り)。timestamp 不要。
- `phase-gate.sh` の rename → 新規 hook ロジックが必要か、単に削除でいいか PBI-C で判断。

---

## Execution

各 PBI を sub-agent にディスパッチして並列/直列実行。

**実行順序**:
1. PBI-A (Schema, foundational) — 単独
2. PBI-B (Scripts), PBI-C (Hooks), PBI-I (Escalation smoke) — A 完了後に並列
3. PBI-D (Skills), PBI-E (Agents), PBI-F (Dashboard), PBI-G (Migration script) — B 完了後に並列
4. PBI-H (Top-level docs) — 全完了後

各 sub-agent には:
- 本 plan doc のパス
- 担当 PBI ID (例: "PBI-A")
- "checkbox を全部チェックして commit するまでが完了"

を伝える。
