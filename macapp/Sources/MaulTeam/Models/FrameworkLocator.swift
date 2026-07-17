//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Locates the maul-team framework the app shells out to (the repo
/// owning scrum-start.sh + dashboard/app.py).
///
/// Resolution order (see `resolved(override:)`):
///   1. An explicit, valid user override checkout (Advanced Settings) — for
///      framework contributors running their own fork.
///   2. The framework **bundled inside the .app**, extracted once to
///      Application Support (the normal path for a distributed build).
///   3. A conventional local checkout (`~/work/maul-team`, …) — a
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

    /// The commit sha make-app.sh baked into the bundle as `.framework-rev`
    /// (truncated to 12 chars), or `nil` for a pre-marker bundle. The version
    /// string alone cannot key the extraction: `git describe --tags` reports
    /// the LAST tag, so a local rebuild at the same tag ships different
    /// content under an identical version.
    static var bundledRevision: String? {
        guard let bundled = bundledPath else { return nil }
        let marker = (bundled as NSString).appendingPathComponent(".framework-rev")
        guard let raw = try? String(contentsOfFile: marker, encoding: .utf8) else { return nil }
        return parseRevisionMarker(raw)
    }

    /// First line of a `.framework-rev` marker, trimmed and truncated to 12
    /// chars; `nil` when the marker is empty/whitespace. Pure — unit-testable
    /// without a bundle.
    static func parseRevisionMarker(_ raw: String) -> String? {
        let first = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let rev = first.trimmingCharacters(in: .whitespaces)
        return rev.isEmpty ? nil : String(rev.prefix(12))
    }

    /// Directory name for an extracted framework. Content-keyed when the
    /// bundle carries a revision marker — new content ⇒ new directory — so an
    /// existing extraction is immutable and never needs an in-place refresh.
    /// Pure — unit-testable without a bundle.
    static func extractionDirName(version: String, rev: String?) -> String {
        if let rev, !rev.isEmpty { return "framework-\(version)-\(rev)" }
        return "framework-\(version)"   // pre-marker bundles: legacy naming
    }

    /// Extraction target under Application Support.
    static func supportPath(version: String, rev: String?) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(
            "MaulTeam/\(extractionDirName(version: version, rev: rev))").path
    }

    /// Extract the bundled framework to `~/Library/Application Support/MaulTeam/
    /// framework-<version>-<rev>/` (idempotent). Returns the extracted path, or
    /// `nil` when the app has no bundled framework (dev build). Extraction
    /// gives a user-writable copy so setup-user.sh and per-project deploys can
    /// run without touching the read-only, signed .app bundle.
    @discardableResult
    static func ensureExtracted() -> String? {
        guard let bundled = bundledPath else { return nil }
        let dest = supportPath(version: appVersion, rev: bundledRevision)
        // Content-keyed dirs are immutable, so a valid extraction is current
        // by construction. (Legacy rev-less dirs can go stale across same-
        // version rebuilds; only pre-marker bundles still hit that path.)
        if isValid(dest) { return dest }

        let fm = FileManager.default
        do {
            let parent = (dest as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            // Stage into a temp sibling, then rename into place: a crash
            // mid-copy must never leave a half-populated dir that a later
            // isValid() check would trust.
            let tmp = dest + ".tmp-" + UUID().uuidString
            try fm.copyItem(atPath: bundled, toPath: tmp)   // preserves exec bits
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.moveItem(atPath: tmp, toPath: dest)
            guard isValid(dest) else { return nil }
            cleanupStaleExtractions(keeping: dest)
            return dest
        } catch {
            NSLog("FrameworkLocator: framework extraction failed: \(error)")
            return nil
        }
    }

    /// Best-effort removal of every other `framework-*` entry (older
    /// versions, legacy rev-less dirs, orphaned `.tmp-` staging dirs) next to
    /// a freshly validated extraction. Only shell scripts live there and the
    /// shell reads them at exec time, so sweeping directories that a stray
    /// orphan process might still reference is acceptable. Called only right
    /// after a new extraction — never on the hot resolve path.
    private static func cleanupStaleExtractions(keeping dest: String) {
        let fm = FileManager.default
        let parent = (dest as NSString).deletingLastPathComponent
        let keep = (dest as NSString).lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: parent) else { return }
        for entry in entries where entry.hasPrefix("framework-") && entry != keep {
            try? fm.removeItem(atPath: (parent as NSString).appendingPathComponent(entry))
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
        if let env = ProcessInfo.processInfo.environment["MAUL_TEAM_DIR"], isValid(env) {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/work/maul-team",
            "\(home)/maul-team",
            "\(home)/src/maul-team",
            "\(home)/Developer/maul-team",
            "\(home)/work/claude-scrum-team",
            "\(home)/claude-scrum-team",
            "\(home)/src/claude-scrum-team",
            "\(home)/Developer/claude-scrum-team",
        ]
        return candidates.first(where: isValid) ?? ""
    }
}
