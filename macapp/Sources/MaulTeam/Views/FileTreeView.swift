//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// Project file browser. Single click selects (folders also toggle), arrow
/// keys move the selection (←/→ collapse/expand), Return or double-click
/// opens the file in its own editor window. Framework-owned paths (agents/,
/// skills/, …) show a lock and their edit action is disabled unless Advanced
/// mode is unlocked.
///
/// This is a UI-level guard only — see AppState.advancedUnlocked.
struct FileTreeView: View {
    let rootPath: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var editor: EditorModel

    @State private var root: FileNode
    @State private var expanded: Set<String>
    @State private var selection: String?
    @FocusState private var treeFocused: Bool

    init(rootPath: String) {
        self.rootPath = rootPath
        _root = State(initialValue: FileNode(path: rootPath, root: rootPath))
        _expanded = State(initialValue: [rootPath])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Explorer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleNodes, id: \.node.id) { item in
                            FileRow(
                                node: item.node,
                                depth: item.depth,
                                isExpanded: expanded.contains(item.node.path),
                                isSelected: selection == item.node.path,
                                select: { select(item.node) },
                                open: { openInWindow(item.node) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($treeFocused)
                .onMoveCommand { move($0, proxy: proxy) }
                .onKeyPress(.return) { activateSelection() }
            }
        }
    }

    /// The rows currently on screen: a depth-first walk of expanded folders.
    private var visibleNodes: [(node: FileNode, depth: Int)] {
        var rows: [(FileNode, Int)] = []
        func walk(_ node: FileNode, depth: Int) {
            rows.append((node, depth))
            guard node.isDirectory, expanded.contains(node.path) else { return }
            for child in node.children() { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return rows
    }

    private func select(_ node: FileNode) {
        selection = node.path
        treeFocused = true
        if node.isDirectory { toggle(node) }
    }

    private func toggle(_ node: FileNode) {
        withAnimation(.easeInOut(duration: 0.12)) {
            if expanded.contains(node.path) { expanded.remove(node.path) }
            else { expanded.insert(node.path) }
        }
    }

    private func openInWindow(_ node: FileNode) {
        selection = node.path
        let tab = editor.open(URL(fileURLWithPath: node.path))
        EditorWindowController.shared.open(
            tab: tab, projectRoot: node.root, state: state, model: editor
        )
    }

    private func activateSelection() -> KeyPress.Result {
        guard let node = visibleNodes.first(where: { $0.node.path == selection })?.node else {
            return .ignored
        }
        if node.isDirectory { toggle(node) } else { openInWindow(node) }
        return .handled
    }

    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let rows = visibleNodes
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.node.path == selection }
        var target: String?

        switch direction {
        case .up:
            target = rows[currentIndex.map { max($0 - 1, 0) } ?? 0].node.path
        case .down:
            target = rows[currentIndex.map { min($0 + 1, rows.count - 1) } ?? 0].node.path
        case .right:
            guard let idx = currentIndex else { return }
            let node = rows[idx].node
            guard node.isDirectory else { return }
            if !expanded.contains(node.path) {
                toggle(node)
                target = node.path
            } else if idx + 1 < rows.count, rows[idx + 1].depth > rows[idx].depth {
                target = rows[idx + 1].node.path   // into the first child
            }
        case .left:
            guard let idx = currentIndex else { return }
            let node = rows[idx].node
            if node.isDirectory, expanded.contains(node.path) {
                toggle(node)
                target = node.path
            } else {
                let parent = (node.path as NSString).deletingLastPathComponent
                if parent.count >= rootPath.count { target = parent }
            }
        @unknown default:
            return
        }

        if let target {
            selection = target
            proxy.scrollTo(target)
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
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void

    private var editable: Bool { !node.isProtected || state.advancedUnlocked }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory ? (isExpanded ? "chevron.down" : "chevron.right") : "doc")
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
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .textSelection(.disabled)   // this row selects/opens; don't select the name text
        // Double-click opens files in their editor window; the simultaneous
        // single-tap keeps selection (and folder toggling) instant.
        .gesture(TapGesture(count: 2).onEnded { if !node.isDirectory { open() } })
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu {
            if !node.isDirectory {
                Button("Open") { open() }
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
