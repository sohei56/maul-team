//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

/// Renders a single EditorTab: syntax-highlighted code (editable when the file
/// isn't protected, or when Advanced is unlocked), or an image / binary notice.
/// Hosted in the detached editor windows opened by EditorWindowController.
struct FileEditorView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var tab: EditorTab
    let projectRoot: String

    @State private var editorState = SourceEditorState()
    @AppStorage("editor.wrapLines") private var wrapLines = false

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
                if let pos = editorState.cursorPositions?.first?.start, pos.line > 0 {
                    Text("Ln \(pos.line), Col \(pos.column)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button {
                    tab.undoManager.undo()
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!editable || !tab.undoManager.canUndo)
                    .help("Undo (⌘Z)")
                Button {
                    tab.undoManager.redo()
                } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!editable || !tab.undoManager.canRedo)
                    .help("Redo (⇧⌘Z)")
                Button {
                    editorState.findPanelVisible = !(editorState.findPanelVisible ?? false)
                } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f")
                    .help("Find / Replace (⌘F)")
                Button {
                    wrapLines.toggle()
                } label: { Image(systemName: "text.wrap") }
                    .foregroundStyle(wrapLines ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .help(wrapLines ? "Disable line wrapping" : "Wrap long lines")
                if tab.isDirty { Text("• Edited").font(.caption).foregroundStyle(.orange) }
                Button("Save") { tab.save() }
                    .disabled(!editable || !tab.isDirty)
                    .keyboardShortcut("s")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch tab.kind {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text:
            SourceEditor(
                $tab.text,
                language: CodeLanguage.detectLanguageFrom(url: tab.url),
                configuration: SourceEditorConfiguration(
                    appearance: .init(
                        theme: .maulDark,
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        wrapLines: wrapLines,
                        tabWidth: 2
                    ),
                    behavior: .init(
                        isEditable: editable,
                        indentOption: .spaces(count: 2)
                    ),
                    peripherals: .init(showMinimap: false)
                ),
                state: $editorState,
                undoManager: tab.undoManager
            )
            // The gutter (line numbers + folding ribbon) is a floating subview
            // that draws outside the scroll bounds — without clipping it slides
            // over the toolbar above.
            .clipped()
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
}
