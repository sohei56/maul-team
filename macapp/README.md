# ScrumTeam.app (macOS)

A native macOS shell for the `claude-scrum-team` framework. MVP scope:
a **project picker** plus an editor-like workspace:

```
┌──────────────┬─────────────────┬──────────────┐
│  Explorer    │                 │              │
│  (file tree) │                 │              │
│──────────────│  Scrum Master   │  Dashboard   │
│  Editor      │  (live terminal)│ (live term.) │
│  (tabs,      │                 │              │
│   highlight) │                 │              │
└──────────────┴─────────────────┴──────────────┘
```

Left column: file tree on top, a tabbed code editor below it (files open here;
a tab can be detached into its own draggable window). Center: the Scrum Master
terminal. Right: the Textual dashboard terminal.

## Design (MVP = approach A)

The app does **not** reimplement any backend logic. It shells out to the
framework's own scripts so they remain the single source of truth:

- **Scrum Master pane** runs `scrum-start.sh` with `SCRUM_NO_TMUX=1`, which
  forces the existing no-tmux foreground branch so the SM session lives
  directly inside an embedded [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  terminal. (Prereq checks, framework deployment, and the initial prompt all
  still come from `scrum-start.sh`.)
- **Dashboard pane** runs `python3 dashboard/app.py` in the project directory.
- **New Project** runs `scripts/setup-user.sh` to deploy
  agents/skills/hooks/rules into the chosen folder.

A future iteration can replace the center pane with a native chat UI driving
`claude` programmatically (approach B) without touching the picker or layout.

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

```bash
cd macapp
swift run            # build + launch (debug)
# or open in Xcode:
open Package.swift
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
