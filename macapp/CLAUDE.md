# macapp — launch & build notes

Native macOS shell (SwiftUI + SwiftTerm). See `README.md` for the
architecture; this file is the build/launch contract for agents.

## Launching (use the .app bundle — NOT `swift run`)

To run the app **as a user would see it** (proper Dock icon + front window):

```bash
sh macapp/scripts/make-app.sh        # debug; pass `release` for a release build
open macapp/build/MaulTeam.app
```

`make-app.sh` builds the binary, assembles `build/MaulTeam.app` with an
`Info.plist` + generated `AppIcon.icns` (from `images/macos_icon.png`) + an
ad-hoc signature, then prints the `open` command.

**Do not verify launch behaviour with `swift run`.** `swift run` (and
`swift build`) produce the bare Mach-O at `.build/<config>/MaulTeam` with no
`.app` bundle — so no `Info.plist`, no `CFBundleIconFile`, and macOS shows a
generic/blank "broken" Dock icon. That is a launch-method artifact, not an app
bug. `swift run` is fine only for a quick compile-and-smoke-run where the icon
and bundle identity don't matter.

The `build/MaulTeam.app` checked into your working tree may be **stale** — it
is whatever the last `make-app.sh` produced. Re-run `make-app.sh` after editing
sources before launching, or you will be testing old code.

## Verifying

`swift build --package-path macapp` confirms compilation only. Native window
behaviour (file-tree protection, editor read-only state, etc.) cannot be
inspected from the CLI — launch the `.app` and verify visually.
