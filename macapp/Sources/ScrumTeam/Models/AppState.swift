import Foundation
import SwiftUI

/// Global, observable app state shared between the picker and the workspace.
@MainActor
final class AppState: ObservableObject {
    /// The project currently open in the workspace. `nil` => show the picker.
    @Published var currentProject: Project?

    /// Recently opened projects, most-recent first. Persisted across launches.
    @Published var recents: [Project]

    /// When true, the file tree exposes edit affordances for protected
    /// framework sources (agents/, skills/, rules/, …). Default OFF.
    ///
    /// NOTE: this is a UI-level guard only. The embedded terminals are full
    /// shells, so a determined user can still edit anything from them. MVP
    /// scope deliberately accepts this (prevents accidental edits, not malice).
    ///
    /// Persisted manually to UserDefaults — @AppStorage does not republish
    /// through an ObservableObject, so we back it with @Published + didSet.
    @Published var advancedUnlocked: Bool {
        didSet { UserDefaults.standard.set(advancedUnlocked, forKey: Keys.advancedUnlocked) }
    }

    /// Absolute path to the claude-scrum-team framework checkout (the repo that
    /// owns scrum-start.sh + dashboard/app.py).
    @Published var frameworkPath: String {
        didSet { UserDefaults.standard.set(frameworkPath, forKey: Keys.frameworkPath) }
    }

    private enum Keys {
        static let advancedUnlocked = "advancedUnlocked"
        static let frameworkPath = "frameworkPath"
    }

    init() {
        self.recents = RecentProjectsStore.load()
        self.advancedUnlocked = UserDefaults.standard.bool(forKey: Keys.advancedUnlocked)
        let stored = UserDefaults.standard.string(forKey: Keys.frameworkPath)
        self.frameworkPath = (stored?.isEmpty == false ? stored! : FrameworkLocator.defaultGuess())
    }

    func open(_ project: Project) {
        var p = project
        p.lastOpened = Date()
        recents = RecentProjectsStore.upsert(p, into: recents)
        RecentProjectsStore.save(recents)
        currentProject = p
    }

    func closeProject() {
        currentProject = nil
    }

    func removeRecent(_ project: Project) {
        recents.removeAll { $0.id == project.id }
        RecentProjectsStore.save(recents)
    }

    /// True when frameworkPath points at a usable checkout.
    var frameworkIsValid: Bool {
        FrameworkLocator.isValid(frameworkPath)
    }
}
