import SwiftUI
import AppKit

/// Settings window. Hosts the framework-path configuration and the Advanced
/// edit-unlock toggle that exposes framework sources for editing.
struct AdvancedSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmUnlock = false

    var body: some View {
        Form {
            Section("Framework") {
                HStack {
                    TextField("claude-scrum-team checkout", text: $state.frameworkPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browseFramework() }
                }
                HStack(spacing: 6) {
                    Image(systemName: state.frameworkIsValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(state.frameworkIsValid ? .green : .red)
                    Text(state.frameworkIsValid
                         ? "Valid — scrum-start.sh and dashboard/app.py found"
                         : "Not a framework checkout (missing scrum-start.sh / dashboard/app.py)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Advanced") {
                Toggle(isOn: Binding(
                    get: { state.advancedUnlocked },
                    set: { newValue in
                        if newValue { confirmUnlock = true } else { state.advancedUnlocked = false }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow editing framework sources")
                        Text("Unlocks agents/, skills/, rules/, hooks/, scripts/, dashboard/ in the file tree. Off by default to prevent accidental changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Notes") {
                Text("The Scrum Master pane is a full terminal; the Dashboard and Work Log are native views. The read-only guard applies only to the file tree — it does not block edits made from the Scrum Master shell.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To change the framework itself (agents, skills, hooks/harness), edit the framework checkout directly at the Framework path above. A project's deployed copies under .claude/ are overwritten from the checkout on setup, so the checkout is the source of truth — edit there, not in the project.")
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
