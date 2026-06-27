import SwiftUI

/// The editor-like 3-pane workspace:
///   left   = project file tree (read-only unless Advanced)
///   center = Scrum Master conversation (live terminal)
///   right  = Textual dashboard (live terminal)
///
/// The two terminals come from a long-lived ProjectSession in the SessionStore,
/// so leaving to the picker can keep them running in the background.
struct WorkspaceView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    let project: Project

    @State private var showLeaveDialog = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // The session is created (processes started) in onAppear; until then
            // show a brief placeholder rather than mutating store state in body.
            if let session = sessions.existingSession(for: project.id) {
                panes(session: session)
            } else {
                ProgressView("Starting session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            _ = sessions.session(for: project, frameworkPath: state.frameworkPath)
        }
        .confirmationDialog("Return to Projects?", isPresented: $showLeaveDialog, titleVisibility: .visible) {
            Button("Keep Running in Background") { state.closeProject() }
            Button("Stop and Return", role: .destructive) {
                sessions.stop(project.id)
                state.closeProject()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep Running leaves the Scrum Master and dashboard running in the background — the project shows a green lamp in the Projects list, and reopening it re-attaches to the same session. Stop ends the session and any unsaved conversation state is lost.")
        }
    }

    private func panes(session: ProjectSession) -> some View {
        HSplitView {
            FileTreeView(rootPath: project.path)
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)

            paneContainer(title: "Scrum Master", systemImage: "bubble.left.and.bubble.right.fill") {
                TerminalPaneView(terminal: session.smTerminal)
            }
            .frame(minWidth: 420)

            paneContainer(title: "Dashboard", systemImage: "chart.bar.doc.horizontal") {
                TerminalPaneView(terminal: session.dashboardTerminal)
            }
            .frame(minWidth: 320, idealWidth: 420)
        }
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
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
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
