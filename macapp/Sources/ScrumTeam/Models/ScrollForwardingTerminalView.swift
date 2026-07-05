//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import SwiftTerm

/// Mouse-wheel forwarding for the Scrum Master terminal.
///
/// SwiftTerm's stock `scrollWheel` only ever scrolls its own scrollback
/// buffer. Full-screen TUIs such as the Scrum Master's `claude` session run
/// in the alternate screen buffer (which has no scrollback) and instead
/// expect mouse reporting, so the stock behaviour makes the wheel appear
/// dead. `scrollWheel` is `public` but not `open`, so it cannot be overridden
/// from outside SwiftTerm; instead a local event monitor (installed by
/// `ProjectSession`) intercepts scroll events over the terminal and calls the
/// helper below.
extension LocalProcessTerminalView {
    /// Translate a scroll-wheel event into mouse button 4 / 5 (wheel-up /
    /// wheel-down) events when the running app has mouse reporting enabled.
    /// Returns `true` when the event was forwarded and should be swallowed;
    /// `false` to let SwiftTerm handle its native scrollback.
    func forwardScrollToMouseReporting(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard allowMouseReporting, terminal.mouseMode != .off, event.deltaY != 0 else {
            return false
        }

        let button = event.deltaY > 0 ? 4 : 5            // X11 wheel up / down
        let flags = terminal.encodeButton(
            button: button, release: false,
            shift: false, meta: false, control: false)
        let (col, row) = scrollCellPosition(of: event, terminal: terminal)

        // Match the wheel "velocity" feel of a native terminal.
        let lines = max(1, min(Int(abs(event.deltaY).rounded()), 6))
        for _ in 0..<lines {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
        return true
    }

    /// True when a bare mouse-move (hover, no button down) over this terminal
    /// would be forwarded to the child process as a motion report.
    ///
    /// SwiftTerm encodes button-less motion (mode 1003 / any-event tracking) as
    /// an SGR `CSI<32;col;row m` sequence: the "no button" code (3) is collapsed
    /// to the left-button bits (0) and the final byte becomes `m` (release).
    /// A TUI mouse parser that ignores the motion bit (32) reads that as a plain
    /// left-button release — i.e. a click — so the option Claude has highlighted
    /// under the pointer commits on hover, with no click. `mouseMoved` is
    /// `public` but not `open`, so it cannot be overridden from outside
    /// SwiftTerm; instead `ProjectSession` installs a local `.mouseMoved`
    /// monitor that swallows the event when this returns true. Button presses
    /// (`mouseDown`/`mouseUp`) and drags (`mouseDragged`) are distinct event
    /// types and are left untouched, so click-to-select still works.
    func reportsHoverAsMotion() -> Bool {
        allowMouseReporting && getTerminal().mouseMode.sendMotionEvent()
    }

    /// Pointer location in 0-based terminal cells, derived from the view
    /// geometry (SwiftTerm's own cell metrics are not public API).
    private func scrollCellPosition(of event: NSEvent, terminal: Terminal) -> (col: Int, row: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let cols = max(1, terminal.cols), rows = max(1, terminal.rows)
        let col = min(cols - 1, max(0, Int(p.x / (bounds.width / CGFloat(cols)))))
        let row = min(rows - 1, max(0, Int((bounds.height - p.y) / (bounds.height / CGFloat(rows)))))
        return (col, row)
    }
}
