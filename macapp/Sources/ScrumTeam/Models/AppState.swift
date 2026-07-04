import Foundation
import SwiftUI

/// Global, observable app state shared between the picker and the workspace.
@MainActor
final class AppState: ObservableObject {
    /// The project currently open in the workspace. `nil` => show the picker.
    @Published var currentProject: Project?

    /// The mode chosen for the project being opened. Read once by the workspace
    /// when it starts the session; ignored when re-attaching to a running one.
    @Published var pendingLaunchMode: LaunchMode = .normal

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

    /// User **override** for the framework checkout (Advanced Settings). Empty
    /// means "use the app's built-in framework"; set it only to run your own
    /// fork/checkout. The actual path the app runs is `resolvedFrameworkPath`.
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
        // The override is empty by default (= use the built-in framework). We do
        // NOT pre-fill a checkout guess here — resolvedFrameworkPath handles the
        // built-in and dev-fallback cases.
        self.frameworkPath = UserDefaults.standard.string(forKey: Keys.frameworkPath) ?? ""
        // Warm the built-in framework extraction so the first project opens
        // without a copy delay (no-op for dev builds with no bundle).
        FrameworkLocator.ensureExtracted()
    }

    func open(_ project: Project, mode: LaunchMode = .normal) {
        var p = project
        p.lastOpened = Date()
        recents = RecentProjectsStore.upsert(p, into: recents)
        RecentProjectsStore.save(recents)
        pendingLaunchMode = mode
        currentProject = p
    }

    func closeProject() {
        currentProject = nil
    }

    func removeRecent(_ project: Project) {
        recents.removeAll { $0.id == project.id }
        RecentProjectsStore.save(recents)
    }

    /// The framework the app actually runs: a valid override, else the
    /// extracted built-in copy, else a conventional local checkout.
    var resolvedFrameworkPath: String {
        FrameworkLocator.resolved(override: frameworkPath)
    }

    /// True when the resolved framework (override / built-in / fallback) is
    /// usable — i.e. the app can actually launch.
    var frameworkIsValid: Bool {
        FrameworkLocator.isValid(resolvedFrameworkPath)
    }

    /// True when a non-empty override is set but does not point at a valid
    /// checkout — the only case the Settings UI should flag as an error.
    var overrideIsInvalid: Bool {
        !frameworkPath.isEmpty && !FrameworkLocator.isValid(frameworkPath)
    }
}
