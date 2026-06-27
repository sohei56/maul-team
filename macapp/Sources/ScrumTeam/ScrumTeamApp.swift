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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ScrumTeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if let project = state.currentProject {
                    WorkspaceView(project: project)
                        .environmentObject(state)
                } else {
                    ProjectPickerView()
                        .environmentObject(state)
                }
            }
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
