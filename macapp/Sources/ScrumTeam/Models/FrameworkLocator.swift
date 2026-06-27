import Foundation

/// Locates the claude-scrum-team framework checkout (the repo owning
/// scrum-start.sh). The app shells out to it; it is not bundled in MVP.
enum FrameworkLocator {
    /// A directory is a valid framework checkout if it contains scrum-start.sh
    /// and dashboard/app.py.
    static func isValid(_ path: String) -> Bool {
        let fm = FileManager.default
        let ns = path as NSString
        return fm.fileExists(atPath: ns.appendingPathComponent("scrum-start.sh"))
            && fm.fileExists(atPath: ns.appendingPathComponent("dashboard/app.py"))
    }

    /// Best-effort default: an explicit env override, then a few conventional
    /// checkout locations. The user can always correct it in Advanced settings.
    static func defaultGuess() -> String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_SCRUM_TEAM_DIR"], isValid(env) {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/work/claude-scrum-team",
            "\(home)/claude-scrum-team",
            "\(home)/src/claude-scrum-team",
            "\(home)/Developer/claude-scrum-team",
        ]
        return candidates.first(where: isValid) ?? ""
    }
}
