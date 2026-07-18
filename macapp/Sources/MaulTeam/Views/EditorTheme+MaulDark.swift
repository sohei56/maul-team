//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import AppKit
import CodeEditSourceEditor

extension EditorTheme {
    /// Atom One Dark palette, matching the "atom-one-dark" Highlightr theme
    /// the editor shipped with before the CodeEditSourceEditor migration.
    static let maulDark = EditorTheme(
        text: .init(color: NSColor(hex: 0xABB2BF)),
        insertionPoint: NSColor(hex: 0x528BFF),
        invisibles: .init(color: NSColor(hex: 0x3B4048)),
        background: NSColor(hex: 0x282C34),
        lineHighlight: NSColor(hex: 0x2C313C),
        selection: NSColor(hex: 0x3E4451),
        keywords: .init(color: NSColor(hex: 0xC678DD)),
        commands: .init(color: NSColor(hex: 0x61AFEF)),
        types: .init(color: NSColor(hex: 0xE5C07B)),
        attributes: .init(color: NSColor(hex: 0xD19A66)),
        variables: .init(color: NSColor(hex: 0xE06C75)),
        values: .init(color: NSColor(hex: 0xD19A66)),
        numbers: .init(color: NSColor(hex: 0xD19A66)),
        strings: .init(color: NSColor(hex: 0x98C379)),
        characters: .init(color: NSColor(hex: 0x56B6C2)),
        comments: .init(color: NSColor(hex: 0x5C6370), italic: true)
    )
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
