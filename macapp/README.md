# MaulTeam.app (macOS)

A native macOS shell for the `maul-team` framework. MVP scope:
a **project picker** plus an editor-like workspace:

```
┌──────────────┬─────────────────┬──────────────┐
│  Explorer    │  Scrum Master   │  Dashboard   │
│  (file tree) │  (live terminal)│  (native:    │
│──────────────│─────────────────│   project,   │
│  Editor      │  Work Log       │   PBI board, │
│  (tabs,      │  (native        │   integration│
│   highlight) │   activity log) │   results)   │
└──────────────┴─────────────────┴──────────────┘
```

- **Left**: file tree on top, a tabbed code editor below it (files open here;
  a tab can be detached into its own draggable window).
- **Center**: the Scrum Master terminal on top, a native Work Log below it.
- **Right**: a native dashboard — project/sprint overview, the PBI board
  (click a PBI for details), and Integration Sprint test results.

## Design (MVP = approach A)

The app does **not** reimplement any backend logic. It shells out to the
framework's own scripts so they remain the single source of truth:

- **Scrum Master pane** runs `scrum-start.sh` with `SCRUM_NO_TMUX=1`, which
  forces the existing no-tmux foreground branch so the SM session lives
  directly inside an embedded [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  terminal. (Prereq checks, framework deployment, and the initial prompt all
  still come from `scrum-start.sh`.)
- **Dashboard + Work Log** are native SwiftUI views (`DashboardModel`) that poll
  the project's `.scrum/*.json` every 2s — the same state the Textual dashboard
  reads (state/sprint/backlog, per-PBI `pbi/<id>/state.json`, `test-results.json`,
  `communications.json`, `dashboard.json`). No Python dashboard process runs.
- **New Project** runs `scripts/setup-user.sh` to deploy
  agents/skills/hooks/rules into the chosen folder.

A future iteration can replace the Scrum Master pane with a native chat UI
driving `claude` programmatically (approach B) without touching the layout.

## Background sessions

Each open project's SM + dashboard processes are owned by a long-lived
`ProjectSession` in `SessionStore`, not by the workspace view. Returning to the
picker therefore offers a choice (confirmation dialog):

- **Keep Running** — keep the session running in the background; the project
  shows a green **Running** lamp in the picker, and reopening it re-attaches to
  the same live session (scrollback + state preserved).
- **Stop** — SIGTERM both processes and discard the session.

A running session can also be stopped from the picker via the project's context
menu. Sessions do not survive quitting the app.

## Editor

The center pane is a tabbed code editor backed by
[CodeEditor](https://github.com/ZeeZide/CodeEditor) (Highlightr / highlight.js):

- Clicking a file in the Explorer opens it as a tab with syntax highlighting
  (dark `atom-one-dark` theme). Images preview inline; large/binary files show
  a notice.
- Editing is allowed for non-protected files (or any file when Advanced is
  unlocked); protected files are read-only. **Save** writes in place (⌘S).
- **Open in New Window** (Explorer or tab context menu) detaches a file into a
  free-floating, draggable window that shares state with its center tab.

Not included in this iteration: line-number gutter and in-editor find (the
chosen component lacks a gutter; adding both would mean swapping to an
`STTextView`-based editor).

## Read-only framework sources

The file tree marks framework-owned paths (`agents/`, `skills/`, `rules/`,
`hooks/`, `scripts/`, `dashboard/`, and their `.claude/`/`.scrum/` deployed
copies) with a lock and disables their edit action. **Advanced Settings**
(⌘,) unlocks editing after a confirmation.

> ⚠️ This guard is **UI-level only**. The Scrum Master and Dashboard panes are
> full terminals, so files can still be edited from a shell. This is an
> accepted MVP limitation, not a security boundary.

## Build & run

Requirements: macOS 13+, Xcode 15+ (Swift 5.9+), network access to fetch
SwiftTerm on first build.

Launch as a user would see it (proper Dock icon + front window):

```bash
sh macapp/scripts/make-app.sh    # build + assemble build/MaulTeam.app (pass `release` for a release build)
open macapp/build/MaulTeam.app
```

`swift run` builds and runs the bare binary, but it has **no `.app` bundle**
(no `Info.plist`, no icon) so macOS shows a generic/blank Dock icon — use it
only for a quick compile-and-smoke-run, not to judge launch behaviour:

```bash
cd macapp
swift run            # dev compile-and-run only (no Dock icon)
open Package.swift   # or open in Xcode
```

On first launch, set the **framework checkout path** in Settings (⌘,) if it
isn't auto-detected. The app looks for `scrum-start.sh` + `dashboard/app.py`;
it probes `$MAUL_TEAM_DIR` and `~/work/maul-team` (and a few
other common locations) by default.

## Distribution

The distribution tooling is **built and wired, but not yet signed** — the first
public release is gated on Apple Developer enrollment (Developer ID certificate
+ notarization credentials). What already works today:

- **universal2 build** — `sh macapp/scripts/make-app.sh release` builds a fat
  (arm64 + x86_64) binary via per-arch native builds + `lipo`, applies Hardened
  Runtime with the minimal entitlements in `macapp/entitlements.plist`, and
  bundles the framework into `.app/Contents/Resources/framework/` (extracted at
  launch to `~/Library/Application Support/MaulTeam/framework-<ver>/`).
- **DMG** — `sh macapp/scripts/make-dmg.sh` produces
  `build/MaulTeam-<ver>.dmg` (zero deps, `hdiutil`) with an `/Applications`
  drag-install symlink; it also signs the DMG when `DEVELOPER_ID_APP` is set.
  The installer window is styled via Finder scripting (background rendered by
  `scripts/dmg-background.swift` at build time, icon layout via `osascript`) —
  the first local run prompts "Terminal wants to control Finder" (TCC
  Automation); click Allow. Styling is best-effort: on failure the script
  ships an unstyled dmg (`DMG_STYLE_STRICT=1` to fail hard, `DMG_NO_STYLE=1`
  to skip).
- **Release CI** — `.github/workflows/release.yml` fires on
  `release: published` (a bare tag push does **not** trigger it — cutting a
  Release is an explicit opt-in): it builds universal2, packages the DMG,
  generates sha256 checksums, and uploads them to the GitHub Release. Code
  signing → `notarytool` → `stapler staple` activate automatically once the
  signing Secrets are present; otherwise the job ships an **unsigned** DMG
  (usable for testing, but Gatekeeper warns end users).

Still pending (blocked on Apple Developer Program enrollment, $99/yr):

- Developer ID signing + notarization + stapling of the `.app`, its bundled
  `.sh` / `python3` / `dylib`, and the DMG (an unsigned `.app` is rejected by
  Gatekeeper on other machines; `swift run` / `swift build` are local-dev only).
- Homebrew tap (`sohei56/homebrew-tap`) + cask referencing the Release DMG.
- Landing page and root-README onboarding links.

Full plan and phase status:
`docs/superpowers/plans/2026-06-29-macapp-distribution-and-onboarding.md`.

## CI

`.github/workflows/swift.yml` runs `swift build` on a macOS runner whenever
`macapp/**` changes (path-filtered to avoid spending macOS minutes on
unrelated commits).

## Status

Builds and runs locally (verified via `scripts/make-app.sh`, debug and
`release`/universal2). The center pane embeds the live SM session (SwiftTerm);
the dashboard and Work Log are native SwiftUI views (no Python dashboard process
runs). Distribution tooling (universal2, framework bundling, DMG, Release CI) is
in place; signing/notarization is pending Apple Developer enrollment (see
[Distribution](#distribution)).

## License

Everything under `macapp/` is **source-available**, not open source, and
is governed by [`macapp/LICENSE`](LICENSE) — the "MaulTeam for Mac —
Source-Available Commercial License". You may view the source, build it,
and use it for your own personal or internal business use; redistribution,
resale, and distributing derivative builds are not permitted. The
MIT License at the repository root does **not** apply here; it covers only
the framework outside `macapp/`. Contributions are accepted under the
[Contributor License Agreement](../docs/CLA.md).
