//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// Landing screen: choose an existing project, open a folder, or create a new
/// one. Selecting a project transitions to the 3-pane workspace.
struct ProjectPickerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var stopTarget: Project?
    @State private var newProjectParent: URL?
    @State private var newProjectName: String = ""
    @State private var showNameInput = false
    @State private var showInfo = false
    @State private var modeTarget: Project?
    @State private var selectedMode: LaunchMode = .normal
    @State private var teamModels = TeamModelConfig()
    @State private var coercedSeats: Set<String> = []

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
        .alert("Stop session?", isPresented: .constant(stopTarget != nil)) {
            Button("Cancel", role: .cancel) { stopTarget = nil }
            Button("Stop", role: .destructive) {
                if let t = stopTarget { sessions.stop(t.id) }
                stopTarget = nil
            }
        } message: {
            Text("This stops the background session (Scrum Master / dashboard) for \(stopTarget?.name ?? ""). Any unsaved conversation state is lost.")
        }
        .alert("New Project", isPresented: $showNameInput) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") { createProjectFolder() }
        } message: {
            Text("Create a new project folder inside \(newProjectParent?.path ?? "").")
        }
        .sheet(item: $modeTarget) { project in
            LaunchModeSheet(
                project: project,
                catalog: state.modelCatalog,
                coercedSeats: coercedSeats,
                selection: $selectedMode,
                teamModels: $teamModels,
                onStart: {
                    let options = LaunchOptions(
                        mode: selectedMode, teamModels: teamModels,
                        flagStyle: LaunchOptions.flagStyle(for: state.modelCatalog))
                    modeTarget = nil
                    state.open(project, options: options)
                },
                onCancel: { modeTarget = nil }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("Maul Team for Claude Code").font(.title.bold())
                Text("Select a project to open").foregroundStyle(.secondary)
            }
            Spacer()
            if !state.frameworkIsValid {
                Label("Framework not found — set it in Settings",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("About & feedback")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPopover() }
        }
        .padding(20)
    }

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projects").font(.headline).padding(.horizontal, 16).padding(.top, 16)
            if state.recents.isEmpty {
                Text("No projects yet").foregroundStyle(.secondary).padding(16)
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
            if sessions.isRunning(project.id) {
                Label("Running", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .help("Running in the background")
            }
        }
        .contentShape(Rectangle())
        .textSelection(.disabled)   // this row navigates; don't select the name text
        .onTapGesture(count: 2) { launch(project) }
        .contextMenu {
            Button(sessions.isRunning(project.id) ? "Reattach to Running Session" : "Open") {
                launch(project)
            }
            if sessions.isRunning(project.id) {
                Button("Stop Session", role: .destructive) { stopTarget = project }
            }
            Divider()
            Button("Remove from Projects") { state.removeRecent(project) }
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

    /// Decide whether to prompt for launch options. A running background
    /// session is re-attached as-is (its original options stand); a fresh
    /// launch opens the mode + team-models sheet, prefilled from the project's
    /// `.scrum/config.json`, then its recents cache, then catalog defaults.
    private func launch(_ project: Project) {
        if sessions.isRunning(project.id) {
            state.open(project)
        } else {
            let prefill = TeamModelPrefill.resolve(project: project, catalog: state.modelCatalog)
            teamModels = prefill.config
            coercedSeats = prefill.coerced
            selectedMode = .normal
            modeTarget = project
        }
    }

    private func openExisting() {
        guard let url = chooseDirectory(prompt: "Open", canCreate: false) else { return }
        launch(Project(path: url.path, lastOpened: Date()))
    }

    /// Pick a parent folder, then prompt for a name; the project is a new
    /// subfolder created under the chosen parent.
    private func createNew() {
        guard let parent = chooseDirectory(prompt: "Choose Location", canCreate: true) else { return }
        newProjectParent = parent
        newProjectName = ""
        showNameInput = true
    }

    private func createProjectFolder() {
        guard let parent = newProjectParent else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty else { errorMessage = "Please enter a project name."; return }
        guard !name.contains("/") else { errorMessage = "The name cannot contain '/'."; return }

        let dir = parent.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            errorMessage = "A folder named \"\(name)\" already exists here."
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            errorMessage = "Could not create the folder: \(error.localizedDescription)"
            return
        }

        let project = Project(path: dir.path, lastOpened: Date())
        busyMessage = "Setting up project…"
        Task {
            let result = await ShellRunner.run(
                ProcessLauncher.deploy(project: project, frameworkPath: state.resolvedFrameworkPath)
            )
            await MainActor.run {
                busyMessage = nil
                if result.exitCode == 0 {
                    launch(project)
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
