//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// Ensures the app behaves as a normal foreground app (Dock icon, menu bar,
/// front window) even when launched as a bare SPM binary rather than a signed
/// .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

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

    /// ⌘Q path: confirm if sessions are running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SessionStore.shared.runningCount == 0 { return .terminateNow }
        return confirmQuit() ? .terminateNow : .terminateCancel
    }

    /// Red-button path: confirm before the window actually closes. Cancel keeps
    /// the window open; Quit stops sessions and lets the close (→ terminate)
    /// proceed without a second prompt (runningCount is 0 by then).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if SessionStore.shared.runningCount == 0 { return true }
        return confirmQuit()
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
}

@main
struct MaulTeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var sessions = SessionStore.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let project = state.currentProject {
                    WorkspaceView(project: project)
                } else {
                    ProjectPickerView()
                }
            }
            .environmentObject(state)
            .environmentObject(sessions)
            .textSelection(.enabled)   // make labels selectable/copyable app-wide
            .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
            }
        }

        Settings {
            AdvancedSettingsView()
                .environmentObject(state)
        }
    }
}
