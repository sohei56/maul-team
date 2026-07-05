//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation
import AppKit
import SwiftTerm

/// A long-lived project session that owns the Scrum Master terminal view (and
/// thus its running process). Held by SessionStore — NOT by any SwiftUI view —
/// so it keeps running after the workspace is dismissed ("background").
///
/// The terminal view is created and its process started exactly once, in init;
/// reopening the project re-parents the same view (preserving live state +
/// scrollback) rather than spawning a fresh process. The dashboard and work log
/// are rendered natively (DashboardModel), so no Python dashboard process runs.
final class ProjectSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, Identifiable {
    let project: Project
    let smTerminal: LocalProcessTerminalView

    /// The mode this session was launched with. Fixed for the session's life —
    /// re-attaching never re-prompts, so the original mode is authoritative.
    let mode: LaunchMode

    /// Local monitor that forwards mouse-wheel scrolling to the running TUI
    /// (see ScrollForwardingTerminalView.swift). Removed on deinit.
    private var scrollMonitor: Any?

    /// Local monitor that swallows bare hover (`.mouseMoved`) events over the
    /// terminal while the TUI has motion reporting on, so a hover does not
    /// commit Claude's highlighted choice (see ScrollForwardingTerminalView
    /// `reportsHoverAsMotion`). Removed on deinit.
    private var hoverMonitor: Any?

    /// Bumped whenever the child process exits, so observers re-read `isRunning`.
    @Published private(set) var stateTick = 0

    var id: String { project.id }

    /// True while the Scrum Master process is alive.
    var isRunning: Bool { smTerminal.process?.running ?? false }

    init(project: Project, frameworkPath: String, mode: LaunchMode = .normal) {
        self.project = project
        self.mode = mode
        self.smTerminal = ComposingTerminalView(frame: .zero)
        super.init()

        smTerminal.processDelegate = self

        // Inherit the user's environment so claude resolves on PATH.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        let sm = ProcessLauncher.scrumMaster(project: project, frameworkPath: frameworkPath, mode: mode)
        smTerminal.startProcess(executable: sm.executable, args: sm.args, environment: envArray)

        installScrollForwarding()
        installHoverMotionSuppression()
    }

    /// Forward mouse-wheel events over the terminal to the running app when it
    /// has mouse reporting on, so the full-screen Scrum Master session scrolls.
    private func installScrollForwarding() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let term = self.smTerminal
            guard let window = term.window, event.window === window else { return event }
            let local = term.convert(event.locationInWindow, from: nil)
            guard term.bounds.contains(local) else { return event }
            return term.forwardScrollToMouseReporting(event) ? nil : event
        }
    }

    /// Swallow bare hover events over the terminal while the running TUI has
    /// motion reporting enabled. SwiftTerm would otherwise encode the hover as
    /// a motion report a TUI can misread as a click, committing the option the
    /// pointer is over without a click (see ScrollForwardingTerminalView
    /// `reportsHoverAsMotion`). Only `.mouseMoved` (button-less hover) is
    /// suppressed; clicks and drags are distinct event types and pass through.
    private func installHoverMotionSuppression() {
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            let term = self.smTerminal
            guard let window = term.window, event.window === window else { return event }
            let local = term.convert(event.locationInWindow, from: nil)
            guard term.bounds.contains(local) else { return event }
            return term.reportsHoverAsMotion() ? nil : event
        }
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
    }

    /// Send SIGTERM to the child. Used by the "stop" actions.
    func terminate() {
        smTerminal.terminate()
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
