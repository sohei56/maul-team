//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// A SwiftUI wrapper around AppKit's NSSplitView. Used instead of SwiftUI's
/// HSplitView/VSplitView because our panes embed AppKit views (terminals, code
/// editor) that would otherwise intercept the mouse and block SwiftUI-drawn
/// dividers. NSSplitView is AppKit-native, so dividers always drag.
///
/// Divider positions are persisted manually (not via NSSplitView's autosave,
/// whose write-on-first-layout timing made first-run defaults unreliable):
/// fractions are saved on every user resize and restored on first layout,
/// falling back to `initialFractions` only when nothing is saved yet.
///
/// Env objects do NOT cross the NSHostingView boundary — inject everything each
/// pane needs onto the AnyView you pass in.
struct SplitContainer: NSViewRepresentable {
    let isVertical: Bool          // true => vertical dividers => side-by-side columns
    let storageKey: String
    let minSizes: [CGFloat]
    let initialFractions: [Double]   // cumulative divider positions (0..1), count = panes-1
    let panes: [AnyView]

    func makeCoordinator() -> Coordinator {
        Coordinator(minSizes: minSizes, initialFractions: initialFractions,
                    storageKey: storageKey, isVertical: isVertical)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let sv = NSSplitView()
        sv.isVertical = isVertical
        sv.dividerStyle = .thin
        sv.delegate = context.coordinator
        for pane in panes {
            sv.addArrangedSubview(NSHostingView(rootView: pane))
        }
        return sv
    }

    func updateNSView(_ sv: NSSplitView, context: Context) {
        context.coordinator.minSizes = minSizes
        for (i, pane) in panes.enumerated() where i < sv.arrangedSubviews.count {
            (sv.arrangedSubviews[i] as? NSHostingView<AnyView>)?.rootView = pane
        }
        context.coordinator.applyInitialIfNeeded(sv)
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var minSizes: [CGFloat]
        let initialFractions: [Double]
        let storageKey: String
        let isVertical: Bool
        private var initialized = false

        init(minSizes: [CGFloat], initialFractions: [Double], storageKey: String, isVertical: Bool) {
            self.minSizes = minSizes
            self.initialFractions = initialFractions
            self.storageKey = storageKey
            self.isVertical = isVertical
        }

        private var fractionsKey: String { "split.\(storageKey).fractions" }

        private func length(_ sv: NSSplitView) -> CGFloat { isVertical ? sv.bounds.width : sv.bounds.height }
        private func size(of view: NSView) -> CGFloat { isVertical ? view.frame.width : view.frame.height }

        /// On first real layout, restore saved divider fractions, or apply the
        /// initial defaults if none are saved.
        func applyInitialIfNeeded(_ sv: NSSplitView) {
            guard !initialized else { return }
            let total = length(sv)
            guard total > 1 else { return }   // wait until laid out
            initialized = true

            let saved = UserDefaults.standard.array(forKey: fractionsKey) as? [Double]
            let fracs = (saved?.count == initialFractions.count) ? saved! : initialFractions
            for (i, f) in fracs.enumerated() {
                sv.setPosition(CGFloat(f) * total, ofDividerAt: i)
            }
        }

        /// Persist the user's divider positions as fractions on every resize.
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard initialized, let sv = notification.object as? NSSplitView else { return }
            let total = length(sv)
            guard total > 1 else { return }
            let subs = sv.arrangedSubviews
            guard subs.count >= 2 else { return }

            var fracs: [Double] = []
            var acc: CGFloat = 0
            for i in 0..<(subs.count - 1) {
                acc += size(of: subs[i]) + sv.dividerThickness
                fracs.append(Double(acc / total))
            }
            UserDefaults.standard.set(fracs, forKey: fractionsKey)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, dividerIndex: Int) -> CGFloat {
            proposedMin + (dividerIndex < minSizes.count ? minSizes[dividerIndex] : 0)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, dividerIndex: Int) -> CGFloat {
            let nextMin = (dividerIndex + 1 < minSizes.count) ? minSizes[dividerIndex + 1] : 0
            return proposedMax - nextMin
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
    }
}
