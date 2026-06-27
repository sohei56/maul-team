import SwiftUI
import AppKit
import SwiftTerm

/// Embeds a real PTY-backed terminal running `command` and renders it as a
/// SwiftUI view. Used for the Scrum Master and dashboard panes.
struct TerminalPaneView: NSViewRepresentable {
    let command: ProcessLauncher.Command

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        // Inherit the user's environment so claude/python3 resolve, and force a
        // truecolor-capable TERM for the Textual dashboard.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        term.startProcess(
            executable: command.executable,
            args: command.args,
            environment: envArray
        )
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Receives process lifecycle callbacks. On exit we leave the last frame on
    /// screen rather than auto-relaunching — the user closes the project to reset.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
