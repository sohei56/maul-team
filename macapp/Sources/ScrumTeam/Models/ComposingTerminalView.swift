import AppKit
import SwiftTerm

/// A `LocalProcessTerminalView` that renders the IME **marked text** (the
/// pre-commit composition string) inline near the caret.
///
/// SwiftTerm's stock `NSTextInputClient` marked-text methods are stubs:
/// `setMarkedText` only flips an internal kitty-composition flag and never
/// stores or draws the composing string, `hasMarkedText()` always returns
/// `false`, and `markedRange()` returns an empty range. As a result any
/// multi-keystroke input method — Japanese/Chinese/Korean, dead keys — shows
/// nothing in the terminal until the composition is committed: the user types
/// blind and the text only appears after the child process echoes the
/// committed string back (on Enter/space confirm).
///
/// This subclass keeps the composing string, reports it through the
/// `NSTextInputClient` marked-text API so the input method behaves correctly,
/// and draws it in a small overlay positioned at the caret. The overlay is
/// torn down on commit (`insertText`) or cancel (`unmarkText`). Mouse-wheel
/// forwarding and hover suppression continue to work — they live in an
/// extension on `LocalProcessTerminalView` and are inherited here.
final class ComposingTerminalView: LocalProcessTerminalView {
    private var markedText = ""
    private lazy var compositionOverlay: CompositionOverlayView = {
        let view = CompositionOverlayView(frame: .zero)
        view.isHidden = true
        addSubview(view)
        return view
    }()

    // MARK: - NSTextInputClient (marked text)

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedText = Self.plainString(from: string)
        if markedText.isEmpty {
            hideComposition()
        } else {
            showComposition()
        }
    }

    override func unmarkText() {
        super.unmarkText()
        clearMarked()
    }

    /// Commit. Drop the composition overlay first, then let SwiftTerm send the
    /// confirmed text to the child process.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        clearMarked()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    override func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    // MARK: - Overlay management

    private func clearMarked() {
        markedText = ""
        hideComposition()
    }

    private func hideComposition() {
        compositionOverlay.isHidden = true
    }

    private func showComposition() {
        compositionOverlay.configure(
            text: markedText,
            font: font,
            foreground: nativeForegroundColor,
            background: nativeBackgroundColor)

        // SwiftTerm's public `firstRect(forCharacterRange:)` returns the caret
        // rect in screen coordinates; map it back to this view so the overlay
        // sits on the caret's line.
        let caretScreenRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        var origin = NSPoint(x: 0, y: bounds.height - compositionOverlay.frame.height)
        if caretScreenRect != .zero, let window {
            let windowRect = window.convertFromScreen(caretScreenRect)
            origin = convert(windowRect.origin, from: nil)
        }

        // Keep the overlay inside the terminal bounds.
        let maxX = max(0, bounds.width - compositionOverlay.frame.width)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), max(0, bounds.height - compositionOverlay.frame.height))

        compositionOverlay.setFrameOrigin(origin)
        compositionOverlay.isHidden = false
    }

    private static func plainString(from string: Any) -> String {
        if let attributed = string as? NSAttributedString { return attributed.string }
        if let ns = string as? NSString { return ns as String }
        if let s = string as? String { return s }
        return ""
    }
}

/// Passive overlay that draws the IME composition string with the terminal's
/// font/colors and an underline (the conventional "uncommitted text" marker).
/// It never intercepts events — `hitTest` returns `nil` so clicks fall through
/// to the terminal underneath.
private final class CompositionOverlayView: NSView {
    private var attributed = NSAttributedString(string: "")
    private var backgroundColor = NSColor.textBackgroundColor

    private static let horizontalPadding: CGFloat = 2
    private static let verticalPadding: CGFloat = 1

    func configure(text: String, font: NSFont, foreground: NSColor, background: NSColor) {
        backgroundColor = background
        attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: foreground,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let textSize = attributed.size()
        setFrameSize(NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: ceil(textSize.height) + Self.verticalPadding * 2))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard attributed.length > 0 else { return }
        attributed.draw(at: NSPoint(x: Self.horizontalPadding, y: Self.verticalPadding))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
