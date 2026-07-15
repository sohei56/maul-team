//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation
import AppKit

/// One open file in the editor. Holds its text + dirty/save state. A tab can be
/// shared between the center editor and a detached window so edits stay in sync.
@MainActor
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published var text = ""
    @Published var isDirty = false
    @Published private(set) var kind: Kind = .loading
    @Published var saveError: String?

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

/// The set of files open as tabs in the center editor.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published var activeID: EditorTab.ID?

    var activeTab: EditorTab? { tabs.first { $0.id == activeID } }

    /// Open (or focus) a file as a center tab, returning its tab.
    @discardableResult
    func open(_ url: URL) -> EditorTab {
        if let existing = tabs.first(where: { $0.url == url }) {
            activeID = existing.id
            return existing
        }
        let tab = EditorTab(url: url)
        tabs.append(tab)
        activeID = tab.id
        return tab
    }

    func close(_ id: EditorTab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeID == id {
            activeID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.last?.id
        }
    }
}
