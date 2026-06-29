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
                selection: $selectedMode,
                onStart: {
                    let mode = selectedMode
                    modeTarget = nil
                    state.open(project, mode: mode)
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
                Text("Scrum Team for Claude Code").font(.title.bold())
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

    /// Decide whether to prompt for a launch mode. A running background session
    /// is re-attached as-is (its original mode stands); a fresh launch opens the
    /// mode picker.
    private func launch(_ project: Project) {
        if sessions.isRunning(project.id) {
            state.open(project)
        } else {
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
                ProcessLauncher.deploy(project: project, frameworkPath: state.frameworkPath)
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

/// Modal shown before a fresh session starts: choose Normal vs Autonomous, with
/// an explanation of each. Re-attaching to a running session skips this.
private struct LaunchModeSheet: View {
    let project: Project
    @Binding var selection: LaunchMode
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How should the team run?").font(.title2.bold())
                Text(project.name).font(.callout).foregroundStyle(.secondary)
            }

            ForEach(LaunchMode.allCases) { mode in
                modeCard(mode)
            }

            if selection == .autonomous {
                autonomousGuidance
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(selection == .autonomous ? "Continue in Terminal" : "Start", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Heads-up shown once Autonomous is selected: the run is configured through
    /// the terminal, not this dialog. Sets the expectation that the next prompts
    /// (sprint count, limits, and — for a new project — the brief brainstorm)
    /// must be answered in the terminal pane.
    private var autonomousGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Setup continues in the terminal", systemImage: "terminal")
                .font(.callout.weight(.semibold))
            guidanceRow(
                "number.square",
                "First, the terminal asks you to set the run limits — how many "
                + "sprints to auto-run, max hours, and so on. Type your answers "
                + "in the terminal pane; the run won't start until you do.")
            if !project.hasBrief {
                guidanceRow(
                    "text.book.closed",
                    "This project has no product brief yet. The terminal then "
                    + "walks you through co-authoring one — finish that Q&A "
                    + "(the \"壁打ち\") in the terminal before the autonomous run begins.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func guidanceRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeCard(_ mode: LaunchMode) -> some View {
        let isSelected = selection == mode
        return Button { selection = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemImage).foregroundStyle(.tint)
                        Text(mode.title).font(.headline)
                        Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(mode.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
