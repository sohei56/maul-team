import SwiftUI
import AppKit

/// Landing screen: choose an existing project, open a folder, or create a new
/// one. Selecting a project transitions to the 3-pane workspace.
struct ProjectPickerView: View {
    @EnvironmentObject var state: AppState
    @State private var busyMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                recentsColumn
                Divider()
                actionsColumn
            }
        }
        .overlay { if let busyMessage { busyOverlay(busyMessage) } }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scrum Team").font(.title.bold())
                Text("Select a project to open").foregroundStyle(.secondary)
            }
            Spacer()
            if !state.frameworkIsValid {
                Label("Framework not found — set it in Settings",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(20)
    }

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.headline).padding(.horizontal, 16).padding(.top, 16)
            if state.recents.isEmpty {
                Text("No recent projects").foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                List {
                    ForEach(state.recents) { project in
                        recentRow(project)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460)
    }

    private func recentRow(_ project: Project) -> some View {
        HStack {
            Image(systemName: project.isInitialized ? "folder.fill" : "folder.badge.plus")
                .foregroundStyle(project.isInitialized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.body.weight(.medium))
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { state.open(project) }
        .contextMenu {
            Button("Remove from Recents") { state.removeRecent(project) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
        }
        .padding(.vertical, 2)
    }

    private var actionsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start").font(.headline)
            Button { openExisting() } label: {
                Label("Open Existing Folder…", systemImage: "folder")
            }
            Button { createNew() } label: {
                Label("New Project…", systemImage: "plus.square.on.square")
            }
            .disabled(!state.frameworkIsValid)

            Spacer()
            Divider()
            SettingsLink {
                Label("Advanced Settings…", systemImage: "gearshape")
            }
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(20)
        .frame(width: 280, alignment: .leading)
    }

    private func busyOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    private func openExisting() {
        guard let url = chooseDirectory(prompt: "Open", canCreate: false) else { return }
        state.open(Project(path: url.path, lastOpened: Date()))
    }

    private func createNew() {
        guard let url = chooseDirectory(prompt: "Create Here", canCreate: true) else { return }
        let project = Project(path: url.path, lastOpened: Date())
        busyMessage = "Setting up project…"
        Task {
            let result = await ShellRunner.run(
                ProcessLauncher.deploy(project: project, frameworkPath: state.frameworkPath)
            )
            await MainActor.run {
                busyMessage = nil
                if result.exitCode == 0 {
                    state.open(project)
                } else {
                    errorMessage = "Setup failed (exit \(result.exitCode)).\n\(result.output.suffix(800))"
                }
            }
        }
    }

    private func chooseDirectory(prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = canCreate
            ? "Choose or create a folder for the new project"
            : "Choose an existing project folder"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
