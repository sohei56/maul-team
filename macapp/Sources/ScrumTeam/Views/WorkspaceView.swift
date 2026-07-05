//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// The editor-like workspace:
///   left   = file tree (top) + tabbed code editor (bottom)
///   center = Scrum Master terminal (top) + native Work Log (bottom)
///   right  = native project/PBI/integration dashboard
///
/// The Scrum Master terminal comes from a long-lived ProjectSession in the
/// SessionStore, so leaving to the picker can keep it running in the background.
/// The dashboard and work log are native, polling the project's `.scrum/` state.
struct WorkspaceView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    let project: Project

    @State private var showLeaveDialog = false
    @State private var showInfo = false
    @StateObject private var editor = EditorModel()
    @StateObject private var dashboard: DashboardModel

    init(project: Project) {
        self.project = project
        _dashboard = StateObject(wrappedValue: DashboardModel(projectPath: project.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let session = sessions.existingSession(for: project.id) {
                panes(session: session)
            } else {
                ProgressView("Starting session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            _ = sessions.session(for: project, frameworkPath: state.resolvedFrameworkPath, mode: state.pendingLaunchMode)
        }
        .task {
            // Poll .scrum/ state for the native dashboard + work log while shown.
            while !Task.isCancelled {
                dashboard.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Return to Projects?", isPresented: $showLeaveDialog, titleVisibility: .visible) {
            Button("Keep Running in Background") { state.closeProject() }
            Button("Stop and Return", role: .destructive) {
                sessions.stop(project.id)
                state.closeProject()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep Running leaves the Scrum Master running in the background — the project shows a green lamp in the Projects list, and reopening it re-attaches to the same session. Stop ends the session and any unsaved conversation state is lost.")
        }
    }

    private func panes(session: ProjectSession) -> some View {
        // NSSplitView-backed; divider positions persist across launches (drag to
        // set your defaults). Env objects must be injected per hosted pane — they
        // do not cross the NSHostingView boundary inside SplitContainer.
        let left = AnyView(
            SplitContainer(
                isVertical: false, storageKey: "ws.left",
                minSizes: [120, 120], initialFractions: [0.504],
                panes: [
                    AnyView(FileTreeView(rootPath: project.path)
                        .environmentObject(editor).environmentObject(state)
                        .textSelection(.enabled)),
                    AnyView(EditorPane(model: editor, projectRoot: project.path)
                        .environmentObject(state)),
                ])
        )
        let center = AnyView(
            SplitContainer(
                isVertical: false, storageKey: "ws.center",
                minSizes: [200, 140], initialFractions: [0.655],
                panes: [
                    AnyView(paneContainer(title: "Scrum Master", systemImage: "bubble.left.and.bubble.right.fill") {
                        TerminalPaneView(terminal: session.smTerminal)
                    }),
                    AnyView(paneContainer(title: "Work Log", systemImage: "list.bullet.rectangle") {
                        WorkLogView(model: dashboard)
                    }.textSelection(.enabled)),
                ])
        )
        let right = AnyView(
            paneContainer(title: "Dashboard", systemImage: "chart.bar.doc.horizontal") {
                DashboardView(model: dashboard)
            }
            .environmentObject(state)
            .textSelection(.enabled)
        )
        return SplitContainer(
            isVertical: true, storageKey: "ws.h",
            minSizes: [180, 360, 300], initialFractions: [0.184, 0.729],
            panes: [left, center, right])
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { showLeaveDialog = true } label: {
                Label("Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 16)
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            Text(project.name).font(.headline)
            Text(project.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            Spacer()

            if state.advancedUnlocked {
                Label("Advanced", systemImage: "lock.open.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { showInfo = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("About & feedback")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPopover() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func paneContainer<Content: View>(
        title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(.secondary)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            Divider()
            content()
        }
    }
}
