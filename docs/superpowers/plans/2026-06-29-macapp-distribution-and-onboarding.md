# macapp 配布 + 開発者オンボーディング動線 作業計画

- **作成日**: 2026-06-29
- **対象**: `macapp/` (ScrumTeam.app, SwiftUI + SwiftTerm)
- **目的**: Mac App を広く開発者に配布し、入ってきやすい動線を作る
- **前提計画**: メモリ `project_macapp_release_plan`（Developer ID 直接配布 /
  Framework 同梱 / 課金後回し で 2026-06-28 承認済）を本計画が引き継ぎ・拡張する

---

## 実装状況 (2026-07-04 更新 — リセット後はここを最初に読む)

| Phase | 内容 | 状態 |
|---|---|---|
| 0 | Apple Developer 登録・証明書・notary キー・ライセンス判断 | **未着手（あなた担当・全署名をブロック）** |
| 1 | universal2 化 + Hardened Runtime + entitlements | **✅ 完了・検証済**（native+lipo、`entitlements.plist`、`make-app.sh`） |
| 2 | sign + notarize + staple スクリプト | **未着手**（Phase0 の証明書待ち。CI 側は条件署名で配線済） |
| 3a | Framework を `.app` へ同梱 | **✅ 完了・検証済**（`make-app.sh` git archive、1.3M） |
| 3b | 起動時 `~/Library/Application Support/...` へ展開・解決 | **✅ 完了・実機起動で展開確認済**（`FrameworkLocator`/`AppState`） |
| 3c | ローカル改変の pristine 差分同期 UI（上書き/保持/マージ） | **未着手** |
| 4 | DMG 生成 | **✅ 完了・検証済**（`make-dmg.sh`、hdiutil、4.7M） |
| 5 | Release CI（`release: published` トリガー・条件署名） | **✅ 実装済**（`.github/workflows/release.yml`。**GH Actions 実走は未検証**） |
| 6 | Homebrew 個人 tap（`sohei56/homebrew-tap`）+ cask | **未着手** |
| 7a | ルート README / README_ja を **Mac-App-first に全面再構成** + macapp/README 配布節更新 | **✅ 完了**（2026-07-04、未コミット。Fable レビュー反映済） |
| 7b-i | Mac App ヒーロー画像 + デモ動画 | **✅ 完了**（`images/macapp-hero.png` 0.6M をコミット。デモは **mp4 → GitHub attachment → README に URL 埋め込み**方式に変更（gif は不採用）。source `demo_macapp.mov` / 派生 `macapp-demo.mp4` は `.gitignore`(`*.mov`/`*.mp4`) で除外し GitHub ホスト。README Demo 節に hero + attachment URL 配線済） |
| 7b-ii | 紹介ページ（`site/` 1枚 + pages.yml デプロイ） | **✅ 実装済・未コミット**（2026-07-04。`site/index.html` = dark mission-control LP、シグネチャ=PBIボード移動アニメ[FLIP]・タイプライタ端末・エージェント編成図、macOS標準フォント・完全自己完結・SEO全タグ[OG/Twitter/JSON-LD SoftwareApplication]。`site/assets/macapp-hero.png` / `robots.txt` / `sitemap.xml` / `.github/workflows/pages.yml`[site/** push でPages公開]。Fable ビルド→事実監査済[demo長さ90秒・build時間・偽DLリンク不在を修正/確認]。**ユーザーのデザインレビュー待ち + GH Actions Pages 実走未検証**） |
| 8 | 法務（利用規約/プライバシー）+ クリーン環境 QA + サポート + 任意 Sparkle | **未着手** |

**コミット済 (branch `fix/cleanup-audit-20260702`, 未push)**: `6815b0b`
(Phase1/3/4/5 + Settings UX)。関連メモリ: `project_macapp_phase3_cicd` /
`project_macapp_release_plan`。

**次セッションの着手候補**: Phase 6（tap/cask 雛形、ただし Release 資産が出るまで
実検証不可）、または Phase 8（法務/QA/サポート）。Phase 7b-ii の LP は実装済で
**ユーザーのデザインレビュー + コミット判断待ち**（本番デプロイは main へ push 後
`pages.yml` が発火、GitHub Pages を repo Settings で有効化する必要あり）。
Phase 0 完了後は Secrets 7件投入 → Phase 2 署名検証。

**Phase 7a 完了メモ (2026-07-04、Fable レビュー2巡目反映)**: `README.md` /
`README_ja.md` を **Mac-App-first に全面再構成**。セクション順 = Why → Demo(Mac App
ヒーロー) → **Get Started(Mac App: install/first-run/Sprint 流れ)** → PO 役割 →
Features(先頭に native Mac app) → **Command line(上級: 旧 Quick Start / autonomous
/ CLI demo.gif / Claude Code バージョン詳細を降格)** → Architecture(macapp/ 追加)。
ヒーローのタグライン/バッジも Mac 前面化。`macapp/README.md` の Distribution 節を
実装済ツール(universal2/DMG/Release CI)+ Phase 0 待ちに書換、Status の native/Textual
矛盾も修正。

**Fable レビュー由来の修正 (事実裏取り済)**: ①brew token 誤り(`sohei56/homebrew-tap/
scrum-team` → Homebrew は `homebrew-` を剥がすため二重化して不在)→ コマンドごと削除。
②「gated only on credentials」は release.yml GH Actions 実走未検証なので過大 → 緩和。
③Claude Code ≥2.1.172 は GUI/CLI 両経路で必須(app も scrum-start.sh を呼ぶ)→ Get
Started の必要要件に明記。④Python 3.9+ も Mac App 経由で必要(scrum-start.sh:155
check_python_prereqs が SCRUM_NO_TMUX 分岐より前で無条件実行)→ 明記。

**Demo 資産は配線済み**（プレースホルダではない）。`images/macapp-hero.png`
（3ペイン全体・Retina）はコミット対象。デモ動画は GitHub の user-attachments に
アップロード済みで、README Demo 節に生の attachment URL を埋め込み済み（gif の
ような巨大バイナリをリポジトリにコミットしない）。source `.mov` / 派生 `.mp4` は
`.gitignore` で除外。撮影自体はユーザー手作業（GUI 実行が要る、Claude は不可）。
**現状すべて未 push なので public 露出リスクは無い。**

**未検証で残る確認**: ① `release.yml` の GH Actions 実走（actionlint/実行未）。
② 実機で新規プロジェクトを開き SM ペインが同梱 framework から起動するか
（展開までは確認済、起動の目視は未）。

---

## 1. 確定事項（覆さない）

承認済の方針判断（前提計画より）:

- 配布チャネル = **Developer ID 直接配布**（Mac App Store は不可。SwiftTerm に
  ログインシェルを埋め `claude`/`tmux`/`git` を子プロセス起動するため App
  Sandbox / ガイドライン 2.5.2 と構造的に衝突）。
- Framework は **.app に同梱**（起動時に
  `~/Library/Application Support/ScrumTeam/framework-<ver>/` へ展開）。
- Enterprise 課金は **後回し**（seam のみ）。

本計画での新規確定（2026-06-29 ユーザー回答）:

- **Homebrew = 個人 tap で開始**（`sohei56/homebrew-tap`）。公式 homebrew-cask
  への昇格は本計画スコープ外（将来検討）。
- **紹介ページ = GitHub Pages 1 枚もの**（`site/` に HTML/CSS、Actions で
  `gh-pages` へデプロイ）。
- **バージョン = 本体 git tag と共有のまま**（`make-app.sh` 現状維持）。

---

## 2. 設計：3 チャネルは「並列」ではなく「1 パイプラインの 3 層」

ユーザー要望の dmg / GitHub Release / Homebrew は独立ワークストリームではない。
GitHub Release が供給源で、dmg と Homebrew はその上の配布面:

```
build(universal2) → Developer ID 署名 → notarize → staple
        │
        ├─ DMG 生成 ─────────────────────────────► ① 直接DL (.dmg)
        │     └─ DMG を GitHub Release に添付 ────► ② GitHub Release 配布
        │            └─ cask が ②のURL+sha256 参照 ► ③ Homebrew (個人tap)
        └─ (任意) appcast 生成 → Sparkle 自動更新
```

**全 3 チャネルの成否は notarization 1 点に集約される。** 未 notarize の .app は
どの経路でも Gatekeeper が「壊れている/開発元不明」で弾き、毎回 右クリック→開く
or `xattr -d com.apple.quarantine` を強いる。「入ってきやすい動線」と未署名配布は
構造的に両立しない。

**バージョン本体タグ共有の帰結**: `v*` タグ push 毎に build→sign→notarize→
Release→cask 更新が走る（docs だけの release でも app が再ビルドされる）。許容。

---

## 3. クリティカルパスと依存

```
Phase 0 (Apple登録・証明書) ──┐  ← 全署名作業をブロック。あなた担当・要 $99/年
                              ▼
Phase 1 (universal2 + Hardened Runtime + entitlements)  ← Phase0と並行着手可
                              ▼
Phase 2 (sign + notarize + staple スクリプト)  ← Phase0 完了が必須
                              ▼
Phase 3 (Framework 同梱 + ローカル同期)  ← Phase2 と密結合（同梱物も署名要）
                              ▼
Phase 4 (DMG 生成)              ← ①直接DL の成果物
                              ▼
Phase 5 (Release CI パイプライン)  ← ②GitHub Release を自動化
                              ▼
Phase 6 (Homebrew 個人 tap + cask)  ← ③、Phase5 の Release 資産に依存
                              ▼
Phase 7 (紹介ページ + repo docs)  ← ①②③の URL が確定してから動線を貼る
                              ▼
Phase 8 (法務 + QA + サポート窓口)
```

並行可能: Phase 1 と（Phase 0 完了待ちの）下流は分離。Phase 7 の **文章・デザイン**
は早期に着手できる（ボタンの URL だけ後で差し込む）。

---

## 4. フェーズ別タスク

### Phase 0 — Apple Developer 登録 / 証明書（あなた担当・ブロッカー）
- [ ] Apple Developer Program 登録（$99/年）
- [ ] Developer ID Application 証明書を作成・Keychain に取り込み
- [ ] notarytool 用 App Store Connect API キー（または app-specific password）発行
- [ ] ライセンスモデル決定（アプリ本体 / proprietary enterprise 機能 / サポート契約
      のどれを課金対象にするか。施行は実装しない）
- **成果物**: 証明書、API キー（CI Secrets 投入用）

### Phase 1 — ビルドの配布対応化
- [ ] `make-app.sh` を universal2 化（`swift build --arch arm64 --arch x86_64`
      または `lipo` 結合）。現状 `Mach-O thin (arm64)` 単体を解消（前提計画で実機確認済）
- [ ] Hardened Runtime + entitlements.plist 追加
      （子プロセス起動・JIT 無し・必要な temporary-exception の最小化）
- [ ] `CFBundleVersion` 単調増加の担保（現状 tag 由来 version を流用、ビルド番号付与）
- **成果物**: `macapp/scripts/make-app.sh`（更新）, `macapp/entitlements.plist`
- **検証**: ローカルビルドは外側サンドボックス下で `sandbox_apply` 失敗 →
  `dangerouslyDisableSandbox` 必須（CI は無関係）

### Phase 2 — 署名 + notarize + staple
- [ ] `macapp/scripts/sign-and-notarize.sh` 新規: `codesign --deep --options runtime`
      → `notarytool submit --wait` → `stapler staple`
- [ ] 同梱する `.sh` / `python3` / `dylib` まで個別署名（notarization はアプリ本体
      署名だけでは通らない — Phase 3 と密結合）
- [ ] `spctl -a -vvv` と `stapler validate` で Gatekeeper 通過を確認
- **成果物**: `sign-and-notarize.sh`
- **検証**: クリーン環境（別 Mac / 新ユーザー）でダウンロード→起動が警告なしで通る

### Phase 3 — Framework 同梱 + ローカル同期
- [ ] `.app` 内 Resources に framework 一式を同梱
- [ ] 起動時に `~/Library/Application Support/ScrumTeam/framework-<ver>/` へ展開
- [ ] pristine コピー保持 + ローカル改変の差分検出 →「上書き / 保持 / マージ」提示
- [ ] `FrameworkLocator.swift` を同梱優先に更新（現状の `~/work/...` プローブを fallback に）
- **成果物**: 同梱ロジック、展開・同期ロジック
- **依存**: Phase 2（同梱物も署名対象）

### Phase 4 — DMG 生成（① 直接DL）
- [ ] `macapp/scripts/make-dmg.sh` 新規: `create-dmg`（または `hdiutil`）で
      背景画像 + /Applications シンボリックリンク付き DMG を生成
- [ ] DMG 自体にも署名（`codesign` DMG）
- **成果物**: `make-dmg.sh`, `ScrumTeam-<ver>.dmg`

### Phase 5 — Release CI パイプライン（② GitHub Release）
- [ ] `.github/workflows/release.yml` 新規:
      `on: release: types: [published]`（**GitHub Release を publish した時だけ**
      走る。`git push --tags` だけでは発火しない＝app リリースは明示オプトイン）
- [ ] checkout は `fetch-depth: 0`（`make-app.sh` の `git describe --tags` が
      動くようタグ込み fetch）。version は `github.event.release.tag_name` 由来
- [ ] ジョブ: checkout → 証明書/キーを Secrets から import → make-app(release,
      universal2) → sign-and-notarize → make-dmg → checksums(sha256) 生成
      → `softprops/action-gh-release` で DMG + sha256 を当該 Release に添付
- [ ] GitHub Secrets 登録: 証明書(p12 base64) / パスワード / notary API キー
- [ ] universal2 は **per-arch native ビルド + lipo** で生成する（`make-app.sh`
      実装済）。**Metal Toolchain は不要**。`swift build --arch arm64 --arch x86_64`
      の一発（swiftbuild バックエンド）は Xcode 26 で SwiftTerm の `Shaders.metal`
      を build 時コンパイルしようとして `cannot execute tool 'metal'` で死ぬ
      （swiftlang/swift-package-manager#9429）。native バックエンドはシェーダを
      bundle リソースとして **コピー**するだけ（SwiftTerm が実行時にコンパイル）
      なので metal を呼ばず、CI でも Metal Toolchain ダウンロード手順が要らない。
      ※ CI が swiftbuild を選ばないよう `make-app.sh release` を使うこと
- [ ] （任意）appcast.xml 生成（Sparkle 用、Phase 後述）
- **成果物**: `release.yml`, Release publish で自動アセット添付
- **設計判断**: トリガーを `release: published` にすることで、本体タグ共有でも
  「docs だけのタグで app が無駄に再 notarize される」問題を回避（§5 リスク表参照）。
  pre-release を除外したい場合は `types: [released]`（正式版のみ）に変更

### Phase 6 — Homebrew 個人 tap（③）
- [ ] 別リポジトリ `sohei56/homebrew-tap` 作成、`Casks/scrum-team.rb` 配置
- [ ] cask は Phase 5 の Release DMG URL + sha256 を参照
- [ ] `release.yml` に tap 自動更新ステップ追加（新 Release の URL/sha256 で
      `scrum-team.rb` を bump し tap リポジトリへ push）
- [ ] 動作確認: `brew tap sohei56/homebrew-tap && brew install --cask scrum-team`
- **成果物**: tap リポジトリ + cask + 自動 bump ステップ

### Phase 7 — 紹介ページ + リポジトリ docs（動線の作り込み）
- [ ] `site/index.html` + CSS（GitHub Pages 1 枚もの）:
      ヒーロー / 3 ペインのスクショ or GIF / 「Download .dmg」「brew install」
      両ボタン / 主要機能 / システム要件 / GitHub リンク
- [ ] `.github/workflows/pages.yml` で `site/` を `gh-pages` へデプロイ
- [ ] ルート `README.md` に **Mac App セクション**新設:
      スクショ、3 つのインストール手段（dmg DL / GitHub Release / brew）、
      CLI フレームワーク版との違い（2 つの読者層を明確に分岐）
- [ ] `README_ja.md` 同期
- [ ] `macapp/README.md` の「Distribution (not in MVP)」節を実配布手順に更新
- [ ] スクリーンショット / デモ GIF を `images/` に追加（現状 macapp の画像なし）
- **成果物**: ランディングページ、README 拡充、画像資産
- **着手前倒し可**: 文章・レイアウトは Phase 0–6 と並行。最終的に URL/版を差し込む

### Phase 8 — 法務 / QA / サポート / 自動更新
- [ ] 利用規約 + プライバシーポリシー（site/ に配置、README からリンク）
- [ ] クリーン環境 QA チェックリスト（別 Mac、Intel/Apple Silicon 両方、
      macOS 14/15、Gatekeeper 警告ゼロ確認）
- [ ] サポート窓口（GitHub Issues テンプレートに macapp 用を追加）
- [ ] （任意・後続）Sparkle 自動更新（EdDSA 署名 + appcast）。
      ※ Homebrew 経由ユーザーは `brew upgrade` が更新路なので Sparkle は
      **直接 DL ユーザー向けのみ**。優先度低、別 PBI 化推奨
- **課金 seam**: ライセンスチェックの seam だけ用意（施行ロジックは実装しない）

---

## 5. リスク・未決事項

| 項目 | 内容 | 対応 |
|---|---|---|
| Apple 登録の遅延 | Phase 0 が全署名をブロック | 最優先着手。並行で Phase 1・7文章を進める |
| notarize 失敗（同梱物署名漏れ） | `.sh`/python/dylib 未署名で reject | Phase 2/3 を一体検証。クリーン環境必須 |
| tag 共有による無駄ビルド | docs タグで app 再 notarize | **解決済**: Phase5 を `release: published` トリガーにし、Release を作った時だけ app が走る（タグ push だけでは発火しない） |
| 2 つの読者層の混線 | CLI フレームワーク vs Mac App | README/site で明確に分岐 |
| 個人 tap の発見性 | 公式 cask より見つけにくい | 紹介ページ + README で brew コマンドを明示。知名度向上後に公式昇格を別途検討 |
| Sparkle と brew の二重更新 | 更新経路が 2 系統 | Sparkle は直接 DL ユーザー限定・後続 PBI |

---

## 6. 推奨着手順

1. **Phase 0**（あなた・ブロッカー）と **Phase 1 + Phase 7 の文章/デザイン**を並行開始
2. Phase 0 完了後 → Phase 2 → 3 → 4 を一気通貫で検証（クリーン環境）
3. Phase 5（Release CI）→ Phase 6（tap）で配布を自動化
4. Phase 7 の URL 差し込み → 公開
5. Phase 8 を順次

関連: [[project_macapp_release_plan]], [[project_macapp_native_shell]],
[[project_plugin_packaging_blocked]]
