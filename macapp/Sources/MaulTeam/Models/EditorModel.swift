//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation
import AppKit
import CodeEditTextView

/// One open file in the editor. Holds its text + dirty/save state, and backs
/// the editor window showing the file.
@MainActor
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published var text = ""
    @Published var isDirty = false
    @Published private(set) var kind: Kind = .loading
    @Published var saveError: String?

    /// Owned here (not left to the editor's default) so the window toolbar's
    /// Undo/Redo buttons can drive and query the same manager the editor uses.
    let undoManager = CEUndoManager()

    enum Kind {
        case loading
        case text
        case image(NSImage)
        case binary(String)
        case tooLarge(Int)
        case error(String)
    }

    private static let maxPreviewBytes = 5_000_000
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "icns"]

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        load()
    }

    func load() {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            if size > Self.maxPreviewBytes { kind = .tooLarge(size); return }

            if Self.imageExtensions.contains(url.pathExtension.lowercased()),
               let img = NSImage(contentsOf: url) {
                kind = .image(img); return
            }

            let data = try Data(contentsOf: url)
            if data.prefix(8000).contains(0) {
                kind = .binary("Binary file — cannot preview as text."); return
            }
            if let s = String(data: data, encoding: .utf8) {
                text = s; kind = .text; return
            }
            kind = .binary("Not a UTF-8 text file.")
        } catch {
            kind = .error(error.localizedDescription)
        }
    }

    func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Registry of files open in editor windows. De-duplicates by URL and keeps
/// tab state alive while a window shows it (EditorWindowController closes the
/// tab when its window goes away).
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []

    /// Return the open tab for a file, creating one if needed.
    @discardableResult
    func open(_ url: URL) -> EditorTab {
        if let existing = tabs.first(where: { $0.url == url }) {
            return existing
        }
        let tab = EditorTab(url: url)
        tabs.append(tab)
        return tab
    }

    func close(_ id: EditorTab.ID) {
        tabs.removeAll { $0.id == id }
    }
}
