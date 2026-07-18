//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import CodeEditSourceEditor

/// Installs and maintains the indent-guide overlay for a `SourceEditor`.
///
/// Conforms to CodeEditSourceEditor's `TextViewCoordinator` — the only public
/// hook that reaches the underlying text view. CESE stores coordinators
/// **weakly** (`TextViewController.WeakCoordinator`), so the host view must
/// keep a strong reference (`@State`) or this object deallocates silently and
/// the guides vanish. See `FileEditorView.guidesCoordinator`.
final class IndentGuidesCoordinator: TextViewCoordinator {
    /// Toggles guide visibility without tearing the overlay down.
    var isEnabled = true {
        didSet { overlay?.isHidden = !isEnabled }
    }

    private weak var controller: TextViewController?
    private var overlay: IndentGuideOverlayView?
    private var observers: [NSObjectProtocol] = []

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        install(in: controller)
    }

    /// Live edits: redraw only the visible strip (draw is dirty-rect bounded).
    func textViewDidChangeText(controller: TextViewController) {
        overlay?.setNeedsDisplay(overlay?.visibleRect ?? .zero)
    }

    func destroy() {
        removeObservers()
        overlay?.removeFromSuperview()
        overlay = nil
        controller = nil
    }

    /// Forces a full overlay redraw (e.g. after a theme / config change whose
    /// values the overlay reads at draw time).
    func refresh() {
        overlay?.needsDisplay = true
    }

    // MARK: - Install / observers

    private func install(in controller: TextViewController) {
        guard let textView = controller.textView else { return }

        // Idempotent: prepareCoordinator is called again if SwiftUI rebuilds the
        // controller, so tear down any prior overlay + observers first.
        removeObservers()
        overlay?.removeFromSuperview()

        let overlay = IndentGuideOverlayView()
        overlay.controller = controller
        overlay.frame = textView.bounds
        overlay.isHidden = !isEnabled
        textView.addSubview(overlay)
        self.overlay = overlay

        // Re-pin the frame on any text-view resize (wrap toggle, window resize,
        // font reflow) — mirrors CESE's own floating-view frame tracking.
        textView.postsFrameChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self, weak textView] _ in
            guard let textView, let overlay = self?.overlay else { return }
            overlay.frame = textView.bounds
            overlay.needsDisplay = true
        }

        // Belt-and-braces scroll backstop; normal scroll redraw comes from
        // AppKit exposing newly-scrolled strips of the document-anchored overlay.
        let scrollObserver = NotificationCenter.default.addObserver(
            forName: TextViewController.scrollPositionDidUpdateNotification, object: controller, queue: .main
        ) { [weak self] _ in
            guard let overlay = self?.overlay else { return }
            overlay.setNeedsDisplay(overlay.visibleRect)
        }

        observers = [frameObserver, scrollObserver]
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
