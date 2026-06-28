import SwiftUI
import AppKit

/// "About & feedback" popover shared by the project picker and the workspace
/// toolbar. Keeps the app version, Scrum-guide link, issue tracker, and the
/// Anthropic trademark notice in a single place.
struct InfoPopover: View {
    private let issuesURL = URL(string: "https://github.com/sohei56/claude-scrum-team/issues")!
    private let scrumGuideURL = URL(string: "https://scrumguides.org/scrum-guide.html")!

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scrum Team for Claude Code").font(.headline)
                    Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("What is Scrum?")
                .font(.callout)
            Link(destination: scrumGuideURL) {
                Label("Read the Scrum Guide", systemImage: "book")
            }
            Text("New to Scrum? The official guide explains the roles, "
                 + "events, and artifacts this app automates.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Questions, bug reports, or feature requests?")
                .font(.callout)
            Link(destination: issuesURL) {
                Label("Open an issue on GitHub", systemImage: "arrow.up.forward.square")
            }
            Text(issuesURL.absoluteString)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            Text("\"Claude\" and \"Claude Code\" are trademarks of Anthropic. "
                 + "This is an independent project, not affiliated with, "
                 + "sponsored by, or endorsed by Anthropic.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }
}
