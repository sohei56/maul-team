//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation
import SwiftUI

// MARK: - Decoded .scrum state (lenient: every field optional)

struct ScrumState: Codable {
    var product_goal: String?
    var current_sprint_id: String?
    var phase: String?
    var updated_at: String?
}

struct Sprint: Codable {
    var id: String?
    var goal: String?
    var type: String?
    var status: String?
    var developers: [Developer]?
    var started_at: String?
    var completed_at: String?
}

struct Developer: Codable, Identifiable {
    var id: String
    var status: String?
    var assigned_work: [String: [String]]?   // role -> pbi ids
    var sub_agents: [String]?
}

struct BacklogItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var description: String?
    var acceptance_criteria: [String]?
    var status: String?
    var priority: Int?
    var sprint_id: String?
    var implementer_id: String?
    var design_doc_paths: [String]?
    var review_doc_path: String?
    var depends_on_pbi_ids: [String]?
    var ux_change: Bool?
    var parent_pbi_id: String?
    var kind: String?
    var paths_touched: [String]?
    var created_at: String?
    var updated_at: String?
}

struct Backlog: Codable {
    var product_goal: String?
    var items: [BacklogItem]?
    var next_pbi_id: Int?
}

struct PbiState: Codable {
    var pbi_id: String?
    var design_round: Int?
    var impl_round: Int?
    var design_status: String?
    var impl_status: String?
    var ut_status: String?
    var coverage_status: String?
    var escalation_reason: String?
    var branch: String?
    var worktree: String?
    var base_sha: String?
    var head_sha: String?
    var paths_touched: [String]?
    var ready_at: String?
    var merged_sha: String?
    var merged_at: String?
    var merge_failure_count: Int?
    var started_at: String?
    var updated_at: String?
}

// Integration Sprint results (.scrum/test-results.json)

struct TestResults: Codable {
    var categories: [TestCategory]?
    var overall_status: String?
    var started_at: String?
    var updated_at: String?
}

struct TestCategory: Codable, Identifiable {
    var name: String
    var status: String?
    var total: Int?
    var passed: Int?
    var failed: Int?
    var skipped: Int?
    var errors: [String]?
    var runner_command: String?
    var executed_at: String?
    var reason: String?

    var id: String { name }
}

// Work Log sources (communications.json messages + dashboard.json events)

struct Communications: Codable {
    var messages: [LogMessage]?
}

struct LogMessage: Codable {
    var timestamp: String?
    var sender_id: String?
    var sender_role: String?
    var recipient_id: String?
    var type: String?
    var content: String?
    var pbi_id: String?
}

struct DashboardEvents: Codable {
    var events: [WorkEvent]?
}

struct WorkEvent: Codable {
    var timestamp: String?
    var type: String?
    var agent_id: String?
    var pbi_id: String?
    var file_path: String?
    var change_type: String?
    var detail: String?
    var status_from: String?
    var status_to: String?
}

/// A unified Work Log row merged from messages and events.
struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date?
    let timestamp: String
    let kind: String
    let who: String
    let text: String
    let pbiID: String?
    let isMessage: Bool
}

/// Loads and periodically refreshes the project's `.scrum/` state for the
/// native dashboard. Reads the same JSON the Textual dashboard reads.
@MainActor
final class DashboardModel: ObservableObject {
    let projectPath: String

    @Published var state: ScrumState?
    @Published var sprint: Sprint?
    @Published var backlog: Backlog?
    @Published var pbiStates: [String: PbiState] = [:]
    @Published var testResults: TestResults?
    @Published var messages: [LogMessage] = []
    @Published var events: [WorkEvent] = []
    @Published var lastRefresh: Date?

    init(projectPath: String) {
        self.projectPath = projectPath
        refresh()
    }

    var currentSprintID: String? { state?.current_sprint_id ?? sprint?.id }

    /// The whole backlog, ordered by PBI number (pbi-001, pbi-002, …). The PBI
    /// board shows all PBIs — matching the Textual dashboard, which does not
    /// filter by sprint.
    var allItems: [BacklogItem] {
        (backlog?.items ?? []).sorted { Self.pbiNumber($0.id) < Self.pbiNumber($1.id) }
    }

    /// PBIs assigned to the current sprint — used for sprint progress.
    var sprintItems: [BacklogItem] {
        guard let sid = currentSprintID else { return [] }
        return allItems.filter { $0.sprint_id == sid }
    }

    /// Numeric part of a PBI id ("pbi-013" -> 13); non-numeric ids sort last.
    static func pbiNumber(_ id: String) -> Int {
        Int(id.split(separator: "-").last ?? "") ?? Int.max
    }

    /// Done count within the current sprint (for the sprint progress bar).
    var doneCount: Int { sprintItems.filter { $0.status == "done" }.count }

    /// Progress denominator — `cancelled` is terminal non-delivery, so it is
    /// excluded from the ratio (mirrors dashboard/app.py).
    var deliverableCount: Int { sprintItems.filter { $0.status != "cancelled" }.count }

    func refresh() {
        state = decode("state.json", as: ScrumState.self)
        sprint = decode("sprint.json", as: Sprint.self)
        backlog = decode("backlog.json", as: Backlog.self)

        var next: [String: PbiState] = [:]
        for item in backlog?.items ?? [] {
            if let s = decode("pbi/\(item.id)/state.json", as: PbiState.self) {
                next[item.id] = s
            }
        }
        pbiStates = next
        testResults = decode("test-results.json", as: TestResults.self)
        messages = decode("communications.json", as: Communications.self)?.messages ?? []
        events = decode("dashboard.json", as: DashboardEvents.self)?.events ?? []
        lastRefresh = Date()
    }

    /// Merged, newest-first Work Log from messages + events.
    var logEntries: [LogEntry] {
        var out: [LogEntry] = []
        for m in messages {
            out.append(LogEntry(
                date: Self.parseDate(m.timestamp),
                timestamp: Self.shortTime(m.timestamp),
                kind: m.type ?? "message",
                who: m.sender_id ?? "?",
                text: m.content ?? "",
                pbiID: m.pbi_id,
                isMessage: true))
        }
        for e in events {
            out.append(LogEntry(
                date: Self.parseDate(e.timestamp),
                timestamp: Self.shortTime(e.timestamp),
                kind: e.type ?? "event",
                who: e.agent_id ?? "—",
                text: Self.describe(e),
                pbiID: e.pbi_id,
                isMessage: false))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private static func describe(_ e: WorkEvent) -> String {
        if let d = e.detail, !d.isEmpty { return d }
        switch e.type {
        case "file_changed":
            return "\(e.change_type ?? "changed") \(e.file_path ?? "")"
        case "status_transition":
            return "\(e.status_from ?? "?") → \(e.status_to ?? "?")"
        default:
            return e.type ?? ""
        }
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFull.date(from: s) ?? iso.date(from: s)
    }

    static func shortTime(_ s: String?) -> String {
        guard let d = parseDate(s) else { return s ?? "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func scrumURL(_ relative: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".scrum")
            .appendingPathComponent(relative)
    }

    private func decode<T: Decodable>(_ relative: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: scrumURL(relative)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Status presentation (mirrors dashboard/app.py maps)

enum PBIStatus {
    static let devManaged: Set<String> = [
        "in_progress_design", "in_progress_impl", "in_progress_pbi_review",
        "in_progress_ut_run", "in_progress_merge",
    ]

    static func isDevManaged(_ s: String) -> Bool { devManaged.contains(s) }

    /// ◆ Developer-managed, ◇ SM-managed.
    static func icon(_ s: String) -> String { isDevManaged(s) ? "◆" : "◇" }

    static func label(_ s: String) -> String {
        [
            "draft": "draft", "refined": "refined", "blocked": "blocked",
            "in_progress_design": "design", "in_progress_impl": "impl",
            "in_progress_pbi_review": "pbi-review", "in_progress_ut_run": "ut-run",
            "in_progress_merge": "merge", "awaiting_cross_review": "await-x-rev",
            "cross_review": "x-review", "escalated": "escalated", "done": "done",
            "cancelled": "cancelled",
        ][s] ?? s
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "done", "awaiting_cross_review", "cross_review": return .green
        case "refined": return .yellow
        case "blocked", "escalated": return .red
        case "in_progress_design": return .cyan
        case "in_progress_impl", "in_progress_pbi_review": return .blue
        case "in_progress_ut_run": return .teal
        case "in_progress_merge": return .purple
        case "draft", "cancelled": return .secondary
        default: return .secondary
        }
    }
}
