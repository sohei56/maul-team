import Foundation
import AppKit
import SwiftTerm

/// A long-lived project session that owns the two terminal views (and thus the
/// running SM + dashboard processes). Held by SessionStore — NOT by any SwiftUI
/// view — so it keeps running after the workspace is dismissed ("background").
///
/// The terminal views are created and their processes started exactly once, in
/// init; reopening the project re-parents these same views (preserving live
/// state + scrollback) rather than spawning fresh processes.
final class ProjectSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, Identifiable {
    let project: Project
    let smTerminal: LocalProcessTerminalView
    let dashboardTerminal: LocalProcessTerminalView

    /// Bumped whenever a child process exits, so observers re-read `isRunning`.
    @Published private(set) var stateTick = 0

    var id: String { project.id }

    /// True while at least one of the two child processes is alive.
    var isRunning: Bool {
        (smTerminal.process?.running ?? false) || (dashboardTerminal.process?.running ?? false)
    }

    init(project: Project, frameworkPath: String) {
        self.project = project
        self.smTerminal = LocalProcessTerminalView(frame: .zero)
        self.dashboardTerminal = LocalProcessTerminalView(frame: .zero)
        super.init()

        smTerminal.processDelegate = self
        dashboardTerminal.processDelegate = self

        // Inherit the user's environment so claude/python3 resolve, and force a
        // truecolor-capable TERM for the Textual dashboard.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        let sm = ProcessLauncher.scrumMaster(project: project, frameworkPath: frameworkPath)
        smTerminal.startProcess(executable: sm.executable, args: sm.args, environment: envArray)

        let dash = ProcessLauncher.dashboard(project: project, frameworkPath: frameworkPath)
        dashboardTerminal.startProcess(executable: dash.executable, args: dash.args, environment: envArray)
    }

    /// Send SIGTERM to both children. Used by the "stop" actions.
    func terminate() {
        smTerminal.terminate()
        dashboardTerminal.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Delegate callbacks may arrive off the main thread; publish on main.
        DispatchQueue.main.async { [weak self] in self?.stateTick += 1 }
    }
}
