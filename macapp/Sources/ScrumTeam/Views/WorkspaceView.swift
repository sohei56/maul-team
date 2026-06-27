import SwiftUI

/// The editor-like 3-pane workspace:
///   left   = project file tree (read-only unless Advanced)
///   center = Scrum Master conversation (live terminal)
///   right  = Textual dashboard (live terminal)
struct WorkspaceView: View {
    @EnvironmentObject var state: AppState
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                FileTreeView(rootPath: project.path)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)

                paneContainer(title: "Scrum Master", systemImage: "bubble.left.and.bubble.right.fill") {
                    TerminalPaneView(command: ProcessLauncher.scrumMaster(
                        project: project, frameworkPath: state.frameworkPath))
                }
                .frame(minWidth: 420)

                paneContainer(title: "Dashboard", systemImage: "chart.bar.doc.horizontal") {
                    TerminalPaneView(command: ProcessLauncher.dashboard(
                        project: project, frameworkPath: state.frameworkPath))
                }
                .frame(minWidth: 320, idealWidth: 420)
            }
        }
        // Re-create terminals when switching projects.
        .id(project.id)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { state.closeProject() } label: {
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
