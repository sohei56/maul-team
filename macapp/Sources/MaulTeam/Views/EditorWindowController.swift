//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import Combine
import SwiftUI

/// Opens a file in its own free-floating, draggable editor window — the sole
/// editor surface (the Explorer opens files here on double-click). Windows are
/// de-duplicated by file URL; closing one releases its tab from EditorModel.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private struct Entry {
        let window: NSWindow
        let tab: EditorTab
        weak var model: EditorModel?
        let dirtyObservation: AnyCancellable
    }

    private static let frameName = "editorWindow"
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var cascadePoint = NSPoint.zero

    /// Tabs with unsaved edits across all open editor windows (quit guard).
    var dirtyTabs: [EditorTab] { entries.values.map(\.tab).filter(\.isDirty) }

    func open(tab: EditorTab, projectRoot: String, state: AppState, model: EditorModel? = nil) {
        // If a window for this file is already up, just focus it.
        if let existing = entries.values.first(where: { $0.tab.url == tab.url })?.window {
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
        window.subtitle = Self.relativePath(of: tab.url, projectRoot: projectRoot)
        window.representedURL = tab.url
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Restore the last editor-window frame (autosave-name registration
        // fails for second and later windows — harmless), then cascade so
        // stacked windows don't cover each other exactly.
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)

        let dirtyObservation = tab.$isDirty.sink { [weak window] dirty in
            window?.isDocumentEdited = dirty
        }
        entries[ObjectIdentifier(window)] = Entry(
            window: window, tab: tab, model: model, dirtyObservation: dirtyObservation
        )
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = entries[ObjectIdentifier(sender)], entry.tab.isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(entry.tab.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            entry.tab.save()
            // On failure keep the window open so the save-error alert is seen.
            return entry.tab.saveError == nil
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Close every editor window without re-prompting — callers that care
    /// about unsaved edits confirm via ``dirtyTabs`` first.
    func closeAll() {
        for window in entries.values.map(\.window) { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.model?.close(entry.tab.id)
    }

    private static func relativePath(of url: URL, projectRoot: String) -> String {
        let root = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        let path = url.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
