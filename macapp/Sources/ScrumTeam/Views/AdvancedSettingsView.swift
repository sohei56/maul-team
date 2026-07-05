//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import AppKit

/// Settings window. Hosts the framework-path configuration and the Advanced
/// edit-unlock toggle that exposes framework sources for editing.
struct AdvancedSettingsView: View {
    /// Canonical framework repository — shown in Settings for contributors who
    /// want to run a fork/local checkout and send improvements back as PRs.
    static let repoURL = "https://github.com/sohei56/claude-scrum-team"

    @EnvironmentObject var state: AppState
    @State private var confirmUnlock = false

    var body: some View {
        Form {
            Section("Using your own framework (contributors & advanced users)") {
                Text("By default the app runs its **built-in copy** of the framework — most people never need to set a path here.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To hack on the framework itself, point the app at your own checkout instead: fork the repository, clone and edit it locally, then select that folder below. The Scrum Master and dashboard will then run from your checkout rather than the built-in copy, so your changes to agents, skills, hooks, and scripts take effect immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/sohei56/claude-scrum-team",
                     destination: URL(string: Self.repoURL)!)
                    .font(.caption)
                HStack {
                    TextField("Built-in (override with your own checkout)", text: $state.frameworkPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browseFramework() }
                }
                HStack(spacing: 6) {
                    let ok = !state.overrideIsInvalid
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(state.frameworkPath.isEmpty
                         ? "Using the built-in framework"
                         : (state.overrideIsInvalid
                            ? "Not a framework checkout (missing scrum-start.sh / dashboard/app.py)"
                            : "Valid override — scrum-start.sh and dashboard/app.py found"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Built an improvement? Please send it back as a pull request to \(Self.repoURL) — contributions are very welcome. 🙌")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Toggle(isOn: Binding(
                    get: { state.advancedUnlocked },
                    set: { newValue in
                        if newValue { confirmUnlock = true } else { state.advancedUnlocked = false }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow editing framework sources in the open project")
                        Text("Removes the read-only lock on framework-owned files (.claude/agents, skills, hooks, rules, and .scrum) in the currently open project's file tree, so you can edit them in place from here. This is per-project and temporary — those deployed copies are overwritten from the framework on the next setup. It is different from \"use your own framework\" above, which changes the framework the app actually runs for every project.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Notes") {
                Text("The Scrum Master pane is a full terminal; the Dashboard and Work Log are native views. The read-only guard applies only to the file tree — it does not block edits made from the Scrum Master shell.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("A project's deployed copies under .claude/ are overwritten from the framework on setup, so the framework (built-in or your override checkout) is the source of truth — edit there, not in the project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .alert("Enable editing of framework sources?", isPresented: $confirmUnlock) {
            Button("Cancel", role: .cancel) {}
            Button("Unlock", role: .destructive) { state.advancedUnlocked = true }
        } message: {
            Text("Changes to agents, skills, hooks, or scripts can break the Scrum workflow. Only proceed if you know what you're doing.")
        }
    }

    private func browseFramework() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select your claude-scrum-team checkout"
        if panel.runModal() == .OK, let url = panel.url {
            state.frameworkPath = url.path
        }
    }
}
