//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// Native Work Log: merged inter-agent messages (communications.json) and work
/// events (dashboard.json), newest first, with a simple source filter.
struct WorkLogView: View {
    @ObservedObject var model: DashboardModel
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", messages = "Messages", events = "Events"
        var id: String { rawValue }
    }

    private var entries: [LogEntry] {
        switch filter {
        case .all: return model.logEntries
        case .messages: return model.logEntries.filter { $0.isMessage }
        case .events: return model.logEntries.filter { !$0.isMessage }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if entries.isEmpty {
                Text("No activity yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(e.timestamp)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kindLabel(e.kind))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(kindColor(e.kind).opacity(0.18), in: Capsule())
                        .foregroundStyle(kindColor(e.kind))
                    Text(e.who).font(.caption.weight(.medium))
                    if let pbi = e.pbiID {
                        Text(pbi).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(e.text).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func kindLabel(_ k: String) -> String {
        k.replacingOccurrences(of: "_", with: " ")
    }

    private func kindColor(_ k: String) -> Color {
        switch k {
        case "escalation", "report": return .red
        case "status_transition": return .blue
        case "task_completed": return .green
        case "review": return .purple
        case "subagent_start", "agent_spawn": return .teal
        case "subagent_stop": return .orange
        case "file_changed", "tool_use": return .secondary
        case "message": return .cyan
        default: return .secondary
        }
    }
}
