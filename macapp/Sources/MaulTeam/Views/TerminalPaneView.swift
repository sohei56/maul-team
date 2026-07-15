//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit
import SwiftTerm

/// Hosts an EXISTING, long-lived terminal view (owned by a ProjectSession) in
/// the SwiftUI tree. On every appear it re-parents the same terminal into a
/// fresh container, so the underlying process and scrollback survive navigation
/// between the workspace and the picker.
struct TerminalPaneView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if terminal.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        terminal.removeFromSuperview()   // detach from any previous container
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }
}
