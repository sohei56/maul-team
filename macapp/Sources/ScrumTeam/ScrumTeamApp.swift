import SwiftUI
import AppKit

/// Ensures the app behaves as a normal foreground app (Dock icon, menu bar,
/// front window) even when launched as a bare SPM binary rather than a signed
/// .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Closing the last window (red button) quits the app, routing through
    /// applicationShouldTerminate below so the quit confirmation also applies.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Confirm before quitting if any project sessions are running in the
    /// background — quitting stops them all (no persistence across launches).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = SessionStore.shared.runningCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Scrum Team?"
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
            return .terminateNow
        }
        return .terminateCancel
    }
}

@main
struct ScrumTeamApp: App {
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
            .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            AdvancedSettingsView()
                .environmentObject(state)
        }
    }
}
