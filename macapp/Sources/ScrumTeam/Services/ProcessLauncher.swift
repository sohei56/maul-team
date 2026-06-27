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
    static func scrumMaster(project: Project, frameworkPath: String) -> Command {
        let start = shellQuote((frameworkPath as NSString).appendingPathComponent("scrum-start.sh"))
        let inner = "cd \(shellQuote(project.path)) && SCRUM_NO_TMUX=1 exec sh \(start)"
        return Command(executable: loginShell, args: ["-lc", inner])
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
