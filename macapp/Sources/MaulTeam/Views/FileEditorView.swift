//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit
import CodeEditor

/// Renders a single EditorTab: syntax-highlighted code (editable when the file
/// isn't protected, or when Advanced is unlocked), or an image / binary notice.
/// Used both in the center editor tabs and in detached editor windows.
struct FileEditorView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var tab: EditorTab
    let projectRoot: String

    private var relativePath: String {
        let root = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        let p = tab.url.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : tab.url.lastPathComponent
    }
    private var isProtected: Bool { ProtectedPaths.isProtected(relativePath) }
    private var editable: Bool { !isProtected || state.advancedUnlocked }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .alert("Save failed", isPresented: .constant(tab.saveError != nil)) {
            Button("OK") { tab.saveError = nil }
        } message: { Text(tab.saveError ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if isProtected {
                Label(editable ? "Protected (unlocked)" : "Protected — read only",
                      systemImage: editable ? "lock.open" : "lock")
                    .font(.caption)
                    .foregroundStyle(editable ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if case .text = tab.kind {
                if tab.isDirty { Text("• Edited").font(.caption).foregroundStyle(.orange) }
                Button("Save") { tab.save() }
                    .disabled(!editable || !tab.isDirty)
                    .keyboardShortcut("s")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch tab.kind {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text:
            CodeEditor(
                source: $tab.text,
                language: Self.language(for: tab.url),
                theme: CodeEditor.ThemeName(rawValue: "atom-one-dark"),
                flags: editable ? [.selectable, .editable, .smartIndent] : [.selectable],
                indentStyle: .softTab(width: 2)
            )
            .onChange(of: tab.text) { tab.isDirty = true }

        case .image(let img):
            ScrollView([.vertical, .horizontal]) {
                Image(nsImage: img).resizable().scaledToFit().padding()
            }

        case .binary(let message):
            unavailable(message, systemImage: "doc.questionmark")

        case .tooLarge(let bytes):
            unavailable("File too large to preview (\(byteString(bytes))).",
                        systemImage: "doc.badge.ellipsis")

        case .error(let message):
            unavailable(message, systemImage: "exclamationmark.triangle")
        }
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open in External App") { NSWorkspace.shared.open(tab.url) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Map a file extension to a highlight.js language id (nil => plain text).
    static func language(for url: URL) -> CodeEditor.Language? {
        let map: [String: String] = [
            "md": "markdown", "markdown": "markdown",
            "json": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini",
            "sh": "bash", "bash": "bash", "zsh": "bash",
            "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
            "swift": "swift", "js": "javascript", "mjs": "javascript",
            "ts": "typescript", "tsx": "typescript", "jsx": "javascript",
            "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
            "java": "java", "kt": "kotlin", "php": "php",
            "html": "xml", "xml": "xml", "css": "css", "scss": "scss",
            "sql": "sql", "diff": "diff", "patch": "diff",
        ]
        if let name = map[url.pathExtension.lowercased()] {
            return CodeEditor.Language(rawValue: name)
        }
        if url.lastPathComponent.lowercased() == "dockerfile" {
            return CodeEditor.Language(rawValue: "dockerfile")
        }
        if url.lastPathComponent.lowercased().hasPrefix("makefile") {
            return CodeEditor.Language(rawValue: "makefile")
        }
        return nil
    }
}
