//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// Center editor area: a tab strip over the open files plus the active editor.
struct EditorPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: EditorModel
    let projectRoot: String

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                tabStrip
                Divider()
            }
            if let active = model.activeTab {
                FileEditorView(tab: active, projectRoot: projectRoot)
                    .id(active.id)
            } else {
                placeholder
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    tabButton(tab)
                    Divider().frame(height: 18)
                }
            }
        }
        .background(.bar)
    }

    private func tabButton(_ tab: EditorTab) -> some View {
        let isActive = tab.id == model.activeID
        return HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary)
            Text(tab.name).font(.callout).lineLimit(1)
            if tab.isDirty {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.activeID = tab.id }
        .contextMenu {
            Button("Open in New Window") {
                EditorWindowController.shared.open(tab: tab, projectRoot: projectRoot, state: state)
            }
            Button("Close") { model.close(tab.id) }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Select a file from the Explorer").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
