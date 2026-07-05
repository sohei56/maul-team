//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation
import Combine

/// Owns every live ProjectSession, keyed by project path. Because the store is
/// an app-level singleton (outliving the workspace view), sessions keep running
/// in the background when the user returns to the picker.
///
/// Not @MainActor: all access happens on the main thread already (SwiftUI
/// bodies, onAppear, and the AppDelegate terminate hook), and the singleton is
/// also reached from the non-isolated AppDelegate.
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    /// Drives picker lamp updates when sessions are added/removed. Per-session
    /// process exits are surfaced by forwarding each session's objectWillChange.
    @Published private(set) var sessionIds: Set<String> = []

    private var sessions: [String: ProjectSession] = [:]
    private var cancellables: [String: AnyCancellable] = [:]

    /// Return the existing session for a project, or create + start one in the
    /// requested mode. `mode` only applies to a freshly created session — an
    /// already-running background session is returned untouched (re-attach).
    func session(for project: Project, frameworkPath: String, mode: LaunchMode = .normal) -> ProjectSession {
        if let existing = sessions[project.id] { return existing }
        let session = ProjectSession(project: project, frameworkPath: frameworkPath, mode: mode)
        sessions[project.id] = session
        cancellables[project.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionIds.insert(project.id)
        return session
    }

    func existingSession(for projectId: String) -> ProjectSession? {
        sessions[projectId]
    }

    /// True if a live (at least one process running) session exists.
    func isRunning(_ projectId: String) -> Bool {
        sessions[projectId]?.isRunning ?? false
    }

    /// Number of sessions with at least one running process.
    var runningCount: Int {
        sessions.values.filter { $0.isRunning }.count
    }

    /// SIGTERM both processes and forget the session.
    func stop(_ projectId: String) {
        sessions[projectId]?.terminate()
        cancellables[projectId] = nil
        sessions[projectId] = nil
        sessionIds.remove(projectId)
    }

    /// SIGTERM every session — used when quitting the app.
    func stopAll() {
        for id in Array(sessions.keys) { stop(id) }
    }
}
