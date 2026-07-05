//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// Read-only project file browser. Folders expand lazily; framework-owned
/// paths (agents/, skills/, …) show a lock and their edit action is disabled
/// unless Advanced mode is unlocked.
///
/// This is a UI-level guard only — see AppState.advancedUnlocked.
struct FileTreeView: View {
    let rootPath: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Explorer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileRow(node: FileNode(path: rootPath, root: rootPath), depth: 0, initiallyExpanded: true)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// A lazily-populated filesystem node. Children are read once, on first access.
final class FileNode: Identifiable {
    let path: String
    let root: String
    let isDirectory: Bool
    private var loaded: [FileNode]?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    /// Path relative to the project root, for protection checks.
    var relativePath: String {
        guard path != root else { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name
    }

    var isProtected: Bool { ProtectedPaths.isProtected(relativePath) }

    init(path: String, root: String) {
        self.path = path
        self.root = root
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    /// Hidden/heavy directories we skip to keep the tree responsive.
    private static let skip: Set<String> = [".git", "node_modules", "__pycache__", ".build", ".DS_Store"]

    func children() -> [FileNode] {
        if let loaded { return loaded }
        guard isDirectory else { loaded = []; return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let nodes = entries
            .filter { !Self.skip.contains($0) }
            .map { FileNode(path: (path as NSString).appendingPathComponent($0), root: root) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }   // dirs first
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        loaded = nodes
        return nodes
    }
}

private struct FileRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var editor: EditorModel
    let node: FileNode
    let depth: Int
    @State var expanded: Bool

    init(node: FileNode, depth: Int, initiallyExpanded: Bool = false) {
        self.node = node
        self.depth = depth
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var editable: Bool { !node.isProtected || state.advancedUnlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if node.isDirectory && expanded {
                ForEach(node.children()) { child in
                    FileRow(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "doc")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .opacity(node.isDirectory ? 1 : 0)
            Image(systemName: iconName).font(.caption).foregroundStyle(iconColor)
            Text(node.name).font(.callout).lineLimit(1)
            if node.isProtected {
                Image(systemName: editable ? "lock.open" : "lock")
                    .font(.caption2).foregroundStyle(editable ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .textSelection(.disabled)   // this row opens the file / toggles the folder; don't select the name text
        .onTapGesture {
            if node.isDirectory { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } }
            else { editor.open(URL(fileURLWithPath: node.path)) }
        }
        .contextMenu {
            if !node.isDirectory {
                Button("Open") { editor.open(URL(fileURLWithPath: node.path)) }
                Button("Open in New Window") {
                    let tab = editor.open(URL(fileURLWithPath: node.path))
                    EditorWindowController.shared.open(tab: tab, projectRoot: node.root, state: state)
                }
                Button(editable ? "Open in External Editor" : "Open Externally (read only here)") { openExternally() }
                    .disabled(!editable)
                Divider()
            }
            Button("Reveal in Finder") { reveal() }
        }
    }

    private var iconName: String {
        if node.isDirectory { return node.isProtected ? "folder.badge.gearshape" : "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "md": return "doc.richtext"
        case "json": return "curlybraces"
        case "sh", "bash": return "terminal"
        case "py": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        node.isProtected ? .orange : (node.isDirectory ? Color.accentColor : .secondary)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    private func openExternally() {
        guard editable else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }
}
