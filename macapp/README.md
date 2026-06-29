# ScrumTeam.app (macOS)

A native macOS shell for the `claude-scrum-team` framework. MVP scope:
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
sh macapp/scripts/make-app.sh    # build + assemble build/ScrumTeam.app (pass `release` for a release build)
open macapp/build/ScrumTeam.app
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
it probes `$CLAUDE_SCRUM_TEAM_DIR` and `~/work/claude-scrum-team` (and a few
other common locations) by default.

## Distribution (not in MVP)

Shipping a runnable `.app` outside your own machine requires an Xcode app
target with an `Info.plist`, a **Developer ID** signature, and **notarization**
(Apple Developer Program, $99/yr). `swift run` / `swift build` produce an
unsigned binary suitable for local development only.

## CI

`.github/workflows/swift.yml` runs `swift build` on a macOS runner whenever
`macapp/**` changes (path-filtered to avoid spending macOS minutes on
unrelated commits).

## Status

Builds and runs locally (verified via `scripts/make-app.sh`). Center/right
panes embed the live SM session and Textual dashboard.
