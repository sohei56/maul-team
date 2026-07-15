//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import SwiftUI

/// Opens the live Scrum Board in its own free-floating, draggable window.
///
/// A macOS `.sheet` is pinned to its parent window and has no title bar, so it
/// cannot be moved. Hosting the board in a standalone `NSWindow` gives it a
/// title bar you can drag anywhere on screen (and `isMovableByWindowBackground`
/// lets you grab the dark board background too), plus resize / minimize.
///
/// Mirrors `EditorWindowController` — the same detached-window pattern the
/// editor uses. The board keeps updating live because `DashboardModel` is a
/// reference type shared with the dashboard, so it goes on polling `.scrum/`.
@MainActor
final class ScrumBoardWindowController: NSObject, NSWindowDelegate {
    static let shared = ScrumBoardWindowController()

    private var window: NSWindow?

    func open(model: DashboardModel) {
        // Single board window — if it's already up, just focus it.
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let root = ScrumBoardView(model: model) { [weak window] in
            window?.close()
        }
        window.title = "Scrum Board"
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Dark, seamless chrome to match the board's mission-control styling,
        // and grab-anywhere dragging so the whole window follows the cursor.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
