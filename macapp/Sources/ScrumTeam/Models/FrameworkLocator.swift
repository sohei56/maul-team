//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Locates the claude-scrum-team framework the app shells out to (the repo
/// owning scrum-start.sh + dashboard/app.py).
///
/// Resolution order (see `resolved(override:)`):
///   1. An explicit, valid user override checkout (Advanced Settings) — for
///      framework contributors running their own fork.
///   2. The framework **bundled inside the .app**, extracted once to
///      Application Support (the normal path for a distributed build).
///   3. A conventional local checkout (`~/work/claude-scrum-team`, …) — a
///      developer fallback for `swift run` builds that have no bundle.
enum FrameworkLocator {
    /// A directory is a valid framework checkout if it contains scrum-start.sh
    /// and dashboard/app.py.
    static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        let ns = path as NSString
        return fm.fileExists(atPath: ns.appendingPathComponent("scrum-start.sh"))
            && fm.fileExists(atPath: ns.appendingPathComponent("dashboard/app.py"))
    }

    // MARK: - Bundled framework (Phase 3)

    /// The framework bundled inside the .app at `Contents/Resources/framework`,
    /// if present and valid. `nil` for a bare `swift run`/`swift build` binary
    /// (no .app bundle), which is how the dev fallback stays in play.
    static var bundledPath: String? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("framework").path,
              isValid(res) else { return nil }
        return res
    }

    /// The app's short version (CFBundleShortVersionString), used to key the
    /// extracted copy so a new app version extracts a fresh framework.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Version-keyed extraction target under Application Support.
    static func supportPath(version: String) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ScrumTeam/framework-\(version)").path
    }

    /// Extract the bundled framework to `~/Library/Application Support/ScrumTeam/
    /// framework-<version>/` (idempotent). Returns the extracted path, or `nil`
    /// when the app has no bundled framework (dev build). Extraction gives a
    /// user-writable copy so setup-user.sh and per-project deploys can run
    /// without touching the read-only, signed .app bundle.
    @discardableResult
    static func ensureExtracted() -> String? {
        guard let bundled = bundledPath else { return nil }
        let dest = supportPath(version: appVersion)
        if isValid(dest) { return dest }

        let fm = FileManager.default
        do {
            let parent = (dest as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            // Remove a partial/invalid prior extraction before copying fresh.
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: bundled, toPath: dest)   // preserves exec bits
            return isValid(dest) ? dest : nil
        } catch {
            NSLog("FrameworkLocator: framework extraction failed: \(error)")
            return nil
        }
    }

    // MARK: - Resolution

    /// The framework the app should actually run, given the user's override
    /// setting (empty = use built-in). Order: valid override → extracted
    /// built-in → conventional local checkout.
    static func resolved(override: String) -> String {
        if isValid(override) { return override }
        if let extracted = ensureExtracted() { return extracted }
        return defaultGuess()
    }

    // MARK: - Dev fallback

    /// Best-effort default for dev builds with no bundle: an explicit env
    /// override, then a few conventional checkout locations.
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
