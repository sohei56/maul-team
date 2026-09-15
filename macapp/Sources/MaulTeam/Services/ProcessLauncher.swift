//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Builds the shell commands the SwiftTerm panes run. Everything is delegated
/// to the framework's own scripts so the app never duplicates backend logic.
///
/// Each command is wrapped in `zsh -lc "cd <project> && exec …"` because
/// SwiftTerm's startProcess has no working-directory parameter; the login
/// shell also gives the user's normal PATH (claude, python3, tmux).
enum ProcessLauncher {
    struct Command {
        let executable: String   // always the login shell
        let args: [String]
    }

    /// Scrum Master session: runs scrum-start.sh forced into its no-tmux
    /// foreground branch so the SM lives directly in this pane.
    ///
    /// In `.autonomous` mode the `--autonomous` flag starts the Ralph-Loop
    /// watchdog instead of an interactive Scrum Master. The framework's own
    /// pre-flight (in the no-tmux branch) co-authors a product brief in this
    /// same pane when none exists, then launches the watchdog. The per-seat
    /// model table travels as flags too (see `scrumStartArguments`).
    ///
    /// We deliberately do NOT `exec` the script: scrum-start.sh aborts with a
    /// non-zero exit (missing `claude`, Python < 3.9, brief-builder abort, a
    /// bad project path, …) *before* it hands the pane to Claude, and under
    /// `exec` the pane process would just die — the terminal blanks with no
    /// hint of why. Instead we keep the login shell as the pane's parent so it
    /// can catch a non-zero exit, print the exit code + a "see the reason
    /// above" footer, and hold the pane on `read` until the user dismisses it.
    /// A clean exit (Claude session ended normally, code 0) closes the pane as
    /// before.
    static func scrumMaster(
        project: Project, frameworkPath: String,
        options: LaunchOptions = LaunchOptions(), seatOrder: [String] = []
    ) -> Command {
        let start = shellQuote((frameworkPath as NSString).appendingPathComponent("scrum-start.sh"))
        let args = scrumStartArguments(options, seatOrder: seatOrder)
        let flags = args.isEmpty ? "" : " " + args.map(shellQuote).joined(separator: " ")
        let rule = "────────────────────────────────────────────"
        let inner = "cd \(shellQuote(project.path)) && SCRUM_NO_TMUX=1 sh \(start)\(flags)"
            + "; code=$?; if [ \"$code\" -ne 0 ]; then"
            + " echo;"
            + " echo '\(rule)';"
            + " echo \"scrum-start.sh exited (code $code) — 起動を中止しました\";"
            + " echo '終了理由は上のメッセージを参照してください。 / See the message above for why.';"
            + " echo 'Enter を押すと閉じます。 / Press Enter to close.';"
            + " echo '\(rule)';"
            + " read -r _;"
            + " fi"
        return Command(executable: loginShell, args: ["-lc", inner])
    }

    /// The argument list handed to `scrum-start.sh`, unquoted. `--autonomous`
    /// comes first; then the team-model flags:
    ///
    /// - `.agentModel`: `--agent-model <seat>=<provider>:<model>[@<effort>]`
    ///   for every seat in `seatOrder` (catalog order) that has a choice. A nil
    ///   model is spelled `default`. Every seat is always sent, so the
    ///   launcher's in-terminal model wizard never fires.
    /// - `.legacy`: `--sm-model <model>` always, `--po-model <model>` only in
    ///   Autonomous mode (the old launcher rejects it otherwise); a seat with
    ///   no model is omitted.
    static func scrumStartArguments(_ options: LaunchOptions, seatOrder: [String]) -> [String] {
        var args: [String] = []
        if options.mode == .autonomous { args.append("--autonomous") }
        switch options.flagStyle {
        case .agentModel:
            for seat in seatOrder {
                guard let choice = options.teamModels[seat] else { continue }
                args += ["--agent-model", "\(seat)=\(choice.flagValue)"]
            }
        case .legacy:
            if let sm = options.teamModels[AgentSeat.scrumMaster.rawValue]?.model {
                args += ["--sm-model", sm]
            }
            if options.mode == .autonomous,
               let po = options.teamModels[AgentSeat.productOwner.rawValue]?.model {
                args += ["--po-model", po]
            }
        }
        return args
    }

    /// One-shot framework deployment into a freshly created project directory.
    /// Mirrors what scrum-start.sh does on first run (setup-user.sh copies
    /// agents/skills/hooks/rules + writes .gitignore). Returns the command to
    /// run; the caller streams it in a terminal or via Process.
    static func deploy(project: Project, frameworkPath: String) -> Command {
        let setup = shellQuote((frameworkPath as NSString).appendingPathComponent("scripts/setup-user.sh"))
        let inner = "cd \(shellQuote(project.path)) && sh \(setup)"
        return Command(executable: loginShell, args: ["-lc", inner])
    }

    // MARK: - helpers

    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// POSIX single-quote escaping for safe interpolation into the -lc string.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
