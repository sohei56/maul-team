//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView

/// Draws indentation guides for the CodeEditSourceEditor text view.
///
/// Installed by ``IndentGuidesCoordinator`` as a passthrough subview of the
/// `TextView` (the scroll view's document view). Because the overlay lives in
/// the text view's *flipped* coordinate space it scrolls with the document for
/// free, and `TextLinePosition.yPos` / `edgeInsets.left` are usable directly
/// with no scroll-offset math. Guides are only ever drawn inside a line's
/// leading-whitespace region, so — even though line-fragment views are forced
/// to the bottom of the subview stack and this overlay therefore draws *above*
/// the glyphs — a guide never crosses a glyph.
final class IndentGuideOverlayView: NSView {
    /// Read at draw time (never cached) so font / theme / indent changes take
    /// effect on the next redraw without any explicit invalidation plumbing.
    weak var controller: TextViewController?

    /// Cap on the leading-whitespace scan for a single pathological line.
    private let maxWhitespaceScan = 400
    /// Cap on the outward walk used to resolve a blank line's continuation
    /// indent, in each direction.
    private let maxBlankRunScan = 100

    // Must match TextView's flipped space so yPos maps straight through.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Passthrough: the overlay must never intercept clicks, selection drags,
    // or the caret — it is purely decorative.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let controller,
              let textView = controller.textView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }

        let font = controller.font
        // NSFont.charWidth is an internal CESE extension, unusable across the
        // module boundary — duplicate its one-line formula host-side.
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard charWidth > 0 else { return }

        let tabWidth = max(controller.tabWidth, 1)
        let indentUnit = indentUnitColumns(for: controller.indentOption, tabWidth: tabWidth)
        guard indentUnit > 0 else { return }

        let insetLeft = layoutManager.edgeInsets.left
        let mutableString = textStorage.mutableString as NSString

        controller.theme.invisibles.color.setFill()

        for position in layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {
            let effIndent = effectiveIndent(
                for: position,
                layoutManager: layoutManager,
                mutableString: mutableString,
                tabWidth: tabWidth
            )
            let levels = effIndent / indentUnit
            guard levels > 0 else { continue }

            let height = firstFragmentHeight(of: position)
            for level in 0..<levels {
                let x = insetLeft + CGFloat(level * indentUnit) * charWidth
                // Cull guides outside the dirty strip (matters when scrolled
                // horizontally); ±1 guards the pixel-alignment rounding.
                guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { continue }
                NSRect(x: x, y: position.yPos, width: 1, height: height).pixelAligned.fill()
            }
        }
    }

    // MARK: - Indent math

    /// The width of one indent level in columns: the space count for
    /// `.spaces`, one tab stop for `.tab`.
    private func indentUnitColumns(for option: IndentOption, tabWidth: Int) -> Int {
        switch option {
        case .spaces(let count):
            return max(count, 1)
        case .tab:
            return tabWidth
        }
    }

    /// Effective indent (in columns) that guides on this line should reflect.
    ///
    /// A content line uses its own leading whitespace. A blank line continues
    /// the guides of its enclosing block: `min(nearest non-blank above, nearest
    /// non-blank below)` — so guides run through blank lines inside a block but
    /// never dangle past a block's last line (conservative, Xcode-like).
    private func effectiveIndent(
        for position: TextLineStorage<TextLine>.TextLinePosition,
        layoutManager: TextLayoutManager,
        mutableString: NSString,
        tabWidth: Int
    ) -> Int {
        let (columns, isBlank) = leadingIndent(
            at: position.range.location, in: mutableString, tabWidth: tabWidth
        )
        guard isBlank else { return columns }

        // Blank line: resolve its continuation indent from non-blank neighbors.
        // A missing neighbor on either side collapses to 0 → no guides. The
        // outward walk is capped; the design defers any per-pass memoization to
        // a later version (perf envelope is microseconds at v1).
        guard let above = nonBlankNeighborIndent(
            from: position.index, step: -1,
            layoutManager: layoutManager, mutableString: mutableString, tabWidth: tabWidth
        ), let below = nonBlankNeighborIndent(
            from: position.index, step: +1,
            layoutManager: layoutManager, mutableString: mutableString, tabWidth: tabWidth
        ) else {
            return 0
        }
        return min(above, below)
    }

    /// Scans leading whitespace starting at `location`, returning the column
    /// count and whether the line is blank (whitespace-only up to its newline
    /// / EOF). Tabs advance to the next multiple of `tabWidth`.
    private func leadingIndent(
        at location: Int, in mutableString: NSString, tabWidth: Int
    ) -> (columns: Int, isBlank: Bool) {
        let length = mutableString.length
        var column = 0
        var index = location
        var scanned = 0
        while index < length, scanned < maxWhitespaceScan {
            let ch = mutableString.character(at: index)
            switch ch {
            case 0x20: // space
                column += 1
            case 0x09: // tab → next tab stop
                column = ((column / tabWidth) + 1) * tabWidth
            case 0x0A, 0x0D: // newline before any content → blank line
                return (0, true)
            default:
                return (column, false)
            }
            index += 1
            scanned += 1
        }
        // Ran off the end (or hit the scan cap) while still whitespace-only.
        return (0, true)
    }

    /// Walks line-by-line from `index` in `step` direction to the nearest
    /// non-blank line, returning its indent columns, or `nil` if none is found
    /// within the cap.
    private func nonBlankNeighborIndent(
        from index: Int, step: Int,
        layoutManager: TextLayoutManager, mutableString: NSString, tabWidth: Int
    ) -> Int? {
        var lineIndex = index + step
        var steps = 0
        while steps < maxBlankRunScan {
            guard let neighbor = layoutManager.textLineForIndex(lineIndex) else { return nil }
            let (columns, isBlank) = leadingIndent(
                at: neighbor.range.location, in: mutableString, tabWidth: tabWidth
            )
            if !isBlank { return columns }
            lineIndex += step
            steps += 1
        }
        return nil
    }

    /// Height of the guide for this line. When the line wraps, guides are drawn
    /// on the first visual fragment only: CESE wraps continuations back to
    /// column 0 (no hanging indent) and this overlay draws above the glyphs, so
    /// a full-height guide would strike through the wrapped text.
    private func firstFragmentHeight(
        of position: TextLineStorage<TextLine>.TextLinePosition
    ) -> CGFloat {
        let fragments = position.data.lineFragments
        guard fragments.count > 1,
              let first = fragments.getLine(atIndex: 0) else {
            return position.height
        }
        return first.data.scaledHeight
    }
}
