import AppKit
import SwiftUI

/// Opens a file in its own free-floating, draggable window (VS Code's "move
/// editor into new window"). The window hosts the SAME EditorTab as the center
/// tab, so edits and dirty state stay in sync between them.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private var windows: [ObjectIdentifier: NSWindow] = [:]

    func open(tab: EditorTab, projectRoot: String, state: AppState) {
        // If a window for this file is already up, just focus it.
        if let existing = windows.values.first(where: { $0.title == tab.name }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let root = FileEditorView(tab: tab, projectRoot: projectRoot)
            .environmentObject(state)
            .frame(minWidth: 480, minHeight: 360)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = tab.name
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[ObjectIdentifier(window)] = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows[ObjectIdentifier(window)] = nil
    }
}
