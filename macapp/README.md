# ScrumTeam.app (macOS)

A native macOS shell for the `claude-scrum-team` framework. MVP scope:
a **project picker** plus an editor-like **3-pane workspace**:

```
┌──────────────┬─────────────────────────┬──────────────────┐
│  Explorer    │     Scrum Master        │    Dashboard     │
│ (file tree,  │  (live terminal —       │ (live terminal — │
│  read-only)  │   claude --agent        │  Textual TUI)    │
│              │   scrum-master)         │                  │
└──────────────┴─────────────────────────┴──────────────────┘
```

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

## Status

Scaffold complete; **not yet compiled** in this environment (SwiftTerm fetch
requires network). Verify with `swift build` before relying on it.
