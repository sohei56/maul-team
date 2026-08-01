//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import Combine
import Foundation
import UserNotifications

/// An outstanding "the team is waiting on you" prompt for one project, decoded
/// from `.scrum/attention.json`.
struct AttentionState: Equatable {
    /// `permission_prompt` / `idle_prompt`. Free-form: an unknown value is
    /// carried through rather than rejected.
    var type: String?
    var message: String?
    var updatedAt: String?
}

/// The file as the framework writes it. Lenient like the dashboard models —
/// every field optional, so a partial or future-shaped file still decodes.
private struct AttentionFile: Codable {
    var pending: Bool?
    var type: String?
    var message: String?
    var agent: String?
    var updated_at: String?
}

/// Watches `.scrum/attention.json` in every open project and surfaces a waiting
/// prompt two ways: a badge on the project's tab (always) and a macOS
/// notification banner (once per prompt, and only when the user is not already
/// looking at that tab).
///
/// App-level singleton like SessionStore: the poll must outlive any view, and
/// the notification delegate reaches it from the AppDelegate. A missing,
/// unreadable or `pending: false` file all mean the same thing — nothing
/// waiting.
@MainActor
final class AttentionMonitor: ObservableObject {
    static let shared = AttentionMonitor()

    /// userInfo key carrying the project path through a posted banner. Read
    /// back in the notification delegate, which runs outside the main actor.
    nonisolated static let projectPathKey = "projectPath"

    /// Projects with an outstanding prompt, keyed by project id (= path).
    @Published private(set) var pending: [String: AttentionState] = [:]

    /// The workspace's AppState, wired by the root view at launch. Used to tell
    /// which tab is on screen (banner suppression) and to switch tabs when a
    /// banner is clicked. Weak — AppState outlives this either way.
    weak var appState: AppState?

    /// `updated_at` of the last banner posted per project: the edge detector
    /// that keeps a still-pending prompt from re-notifying every 2 seconds.
    private var notified: [String: String] = [:]
    private var pollTask: Task<Void, Never>?

    /// Begin the app-lifetime poll and ask for banner permission. Idempotent;
    /// called once from the AppDelegate.
    func start() {
        guard pollTask == nil else { return }
        requestAuthorization()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Bring the app forward and switch to the project a banner was posted for.
    /// Works from the picker too — setting `currentProject` swaps it for the
    /// workspace. A project whose tab was closed meanwhile is ignored.
    func reveal(projectPath: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let project = SessionStore.shared.openProjects.first(where: { $0.id == projectPath })
        else { return }
        appState?.open(project)
    }

    private func refresh() {
        var next: [String: AttentionState] = [:]
        for project in SessionStore.shared.openProjects {
            guard let state = Self.read(projectPath: project.path) else { continue }
            next[project.id] = state
            postBannerIfNew(for: project, state: state)
        }
        // Drop the ledger entry once a prompt clears (or its tab closes) so the
        // next prompt for that project notifies again.
        notified = notified.filter { next[$0.key] != nil }
        pending = next
    }

    /// Post at most one banner per distinct `updated_at`. A prompt the user is
    /// already looking at is still recorded as announced — it has been seen, so
    /// switching away later must not replay it.
    private func postBannerIfNew(for project: Project, state: AttentionState) {
        let stamp = state.updatedAt ?? ""
        guard notified[project.id] != stamp else { return }
        notified[project.id] = stamp
        guard !isOnScreen(project) else { return }
        postBanner(for: project, state: state)
    }

    /// True when the app is frontmost with this project's tab selected.
    private func isOnScreen(_ project: Project) -> Bool {
        NSApp.isActive && appState?.currentProject?.id == project.id
    }

    private func postBanner(for project: Project, state: AttentionState) {
        guard let center = Self.notificationCenter() else { return }
        let content = UNMutableNotificationContent()
        content.title = project.name
        let detail = state.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        content.body = detail.isEmpty ? "Waiting for your input" : "Waiting for your input — \(detail)"
        content.sound = .default
        content.userInfo = [Self.projectPathKey: project.path]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("MaulTeam: could not post attention banner: \(error.localizedDescription)")
            }
        }
    }

    /// Banners are a bonus — a refusal leaves the tab badges working, so the
    /// outcome is only logged.
    private func requestAuthorization() {
        guard let center = Self.notificationCenter() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("MaulTeam: notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                NSLog("MaulTeam: notifications not authorized — tab badges only")
            }
        }
    }

    /// `UNUserNotificationCenter.current()` raises in a process with no bundle
    /// identity (`swift run`, `swift test`), so every access goes through this
    /// gate rather than being reached directly.
    nonisolated static func notificationCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    // MARK: - Reading the file

    nonisolated static func read(projectPath: String) -> AttentionState? {
        let url = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".scrum")
            .appendingPathComponent("attention.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// nil unless the file decodes *and* declares a prompt is pending.
    nonisolated static func parse(_ data: Data) -> AttentionState? {
        guard let file = try? JSONDecoder().decode(AttentionFile.self, from: data),
              file.pending == true
        else { return nil }
        return AttentionState(type: file.type, message: file.message, updatedAt: file.updated_at)
    }
}
