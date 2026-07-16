//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import Foundation

/// Lightweight "Check for Updates…" flow: compares the running version against
/// the latest GitHub release and routes the user to the stable dmg download.
/// Deliberately not a self-updater — the dmg-first install funnel stays the
/// single distribution path (no appcast / signing-key infrastructure).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// GitHub REST endpoint for the newest published (non-draft, non-prerelease)
    /// release. Unauthenticated rate limits are irrelevant at this call volume.
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/sohei56/maul-team/releases/latest")!
    /// Version-less dmg alias re-uploaded by release.yml on every release —
    /// never rots across version bumps.
    private static let downloadURL =
        URL(string: "https://github.com/sohei56/maul-team/releases/latest/download/MaulTeam.dmg")!
    /// Human-readable fallback when the API is unreachable.
    private static let releasesPage =
        URL(string: "https://github.com/sohei56/maul-team/releases/latest")!

    private var checkInFlight = false

    private init() {}

    /// Menu entry point. Fetches the latest release tag and shows the verdict
    /// as an alert. Re-entrant calls while a check is running are ignored.
    func checkForUpdates() {
        guard !checkInFlight else { return }
        checkInFlight = true
        Task {
            defer { checkInFlight = false }
            do {
                let latest = try await fetchLatestVersion()
                presentVerdict(latest: latest)
            } catch {
                presentFailure(error)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    private func fetchLatestVersion() async throws -> String {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let tag = try JSONDecoder().decode(Release.self, from: data).tagName
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Dev builds (bare `make-app.sh` without a tag) carry 0.0.0, so they always
    /// see "update available" — harmless, and useful for exercising the flow.
    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private func presentVerdict(latest: String) {
        let current = currentVersion
        let alert = NSAlert()
        if latest.compare(current, options: .numeric) == .orderedDescending {
            alert.messageText = "Version \(latest) is available"
            alert.informativeText = "You have \(current). Download the latest dmg "
                + "and drag MaulTeam into Applications to update."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.downloadURL)
            }
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText = "MaulTeam \(current) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = error.localizedDescription
            + "\n\nYou can check the releases page directly."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }
}
