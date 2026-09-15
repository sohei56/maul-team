//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Finds provider CLIs (`claude`, `codex`) the way the Scrum Master pane will:
/// through the user's login shell, so PATH additions from `.zprofile` count.
/// Advisory only — the launch sheet shows a warning, it never blocks on this.
enum CLIProbe {
    /// The resolved path of `name` on the login shell's PATH, or nil when
    /// `command -v` finds nothing (or the shell cannot be run).
    static func locate(_ name: String) async -> String? {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        let command = ProcessLauncher.Command(
            executable: ProcessLauncher.loginShell,
            args: ["-lc", "command -v \(ProcessLauncher.shellQuote(name))"])
        let result = await ShellRunner.run(command)
        guard result.exitCode == 0 else { return nil }
        // The login shell may print rc noise before the answer; the resolved
        // path is the last non-empty line.
        let lines = result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return last
    }
}
