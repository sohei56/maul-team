//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit
import Sparkle
import UserNotifications

/// Ensures the app behaves as a normal foreground app (Dock icon, menu bar,
/// front window) even when launched as a bare SPM binary rather than a signed
/// .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Start watching every open project's .scrum/attention.json. The
        // delegate must be set before the first banner is posted; both calls
        // no-op in an unbundled process, where there is no notification center.
        AttentionMonitor.notificationCenter()?.delegate = self
        AttentionMonitor.shared.start()

        // Become the main window's delegate so the red close button is confirmed
        // BEFORE the window closes — otherwise the window vanishes first and a
        // Cancel leaves the app with no window to return to.
        DispatchQueue.main.async { [weak self] in
            // The main window — exclude detached editor windows (owned by
            // EditorWindowController). None exist yet at launch, so this is it.
            NSApp.windows.first(where: { !($0.delegate is EditorWindowController) })?.delegate = self
        }
    }

    /// Closing the last window quits the app (the confirmation happens earlier,
    /// in windowShouldClose, so by here any sessions are already stopped).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q path: guard unsaved editor windows first (quitting skips their
    /// per-window close confirmation), then confirm if sessions are running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = EditorWindowController.shared.dirtyTabs
        if !dirty.isEmpty && !confirmDiscardEdits(names: dirty.map(\.name)) {
            return .terminateCancel
        }
        if SessionStore.shared.runningCount == 0 { return .terminateNow }
        return confirmQuit() ? .terminateNow : .terminateCancel
    }

    private func confirmDiscardEdits(names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard unsaved editor changes?"
        alert.informativeText = "Unsaved changes in: \(names.joined(separator: ", "))"
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Red-button path: confirm before the window actually closes. Cancel keeps
    /// the window open; Quit stops sessions and lets the close (→ terminate)
    /// proceed without a second prompt (runningCount is 0 by then).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirty = EditorWindowController.shared.dirtyTabs
        if !dirty.isEmpty && !confirmDiscardEdits(names: dirty.map(\.name)) {
            return false
        }
        if SessionStore.shared.runningCount > 0 && !confirmQuit() { return false }
        // Closing the main window means quitting — take the auxiliary editor /
        // Scrum Board windows down too, or they keep the app alive headless.
        EditorWindowController.shared.closeAll()
        ScrumBoardWindowController.shared.closeBoard()
        return true
    }

    /// Show the quit confirmation. Returns true if the user chose Quit (and
    /// stops all background sessions); false to stay in the app.
    private func confirmQuit() -> Bool {
        let running = SessionStore.shared.runningCount
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Maul Team?"
        alert.informativeText = """
        \(running) project session\(running == 1 ? "" : "s") \
        (Scrum Master / dashboard) \(running == 1 ? "is" : "are") running in the \
        background. Quitting stops \(running == 1 ? "it" : "them all") and any \
        unsaved conversation state is lost.
        """
        alert.addButton(withTitle: "Quit")     // first button = default
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            SessionStore.shared.stopAll()
            return true
        }
        return false
    }

    // MARK: - Attention banners

    /// Banner even when the app is frontmost: AttentionMonitor already skips
    /// posting for the tab the user is looking at, so anything arriving here is
    /// about a project they are not watching.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a banner brings the app forward and switches to that project.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let path = info[AttentionMonitor.projectPathKey] as? String else { return }
        await AttentionMonitor.shared.reveal(projectPath: path)
    }
}

@main
struct MaulTeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var sessions = SessionStore.shared
    @StateObject private var attention = AttentionMonitor.shared

    // Sparkle's updater controller. The documented SwiftUI pattern is a plain
    // `let` on the App struct: `startingUpdater: true` kicks off scheduled
    // checks (SUEnableAutomaticChecks is unset, so Sparkle asks for consent on
    // the 2nd launch first). Delegates are nil — the standard user driver
    // handles the whole UI.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            Group {
                if let project = state.currentProject {
                    // Identity must follow the project: switching tabs A→B keeps
                    // the view alive otherwise, and its @StateObject dashboard
                    // (bound to the path at init) plus the file tree's @State
                    // would stay on the old project.
                    WorkspaceView(project: project).id(project.id)
                } else {
                    ProjectPickerView()
                }
            }
            .environmentObject(state)
            .environmentObject(sessions)
            .environmentObject(attention)
            .textSelection(.enabled)   // make labels selectable/copyable app-wide
            .frame(minWidth: 1100, minHeight: 700)
            // The monitor needs the workspace state to know which tab is on
            // screen (banner suppression) and to switch tabs from a banner
            // click; AppState is a @StateObject here, not a singleton.
            .onAppear { attention.appState = state }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            AdvancedSettingsView()
                .environmentObject(state)
        }
    }
}
