//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// A live Kanban of the current Sprint's PBIs across the real PBI-pipeline
/// stages. Cards are positioned by each PBI's 13-value `status`; as the
/// DashboardModel re-polls `.scrum/` (~2s) and a status changes, the card
/// animates from its old column to the new one via `matchedGeometryEffect` —
/// so you can literally watch a PBI move design → impl → review → ut → merge
/// → cross-review → done in real time.
///
/// Dark, mission-control styling to echo the marketing landing page. Reuses
/// `StatusBadge` / `PBIStatus` so the color language matches the rest of the
/// app.
struct ScrumBoardView: View {
    @ObservedObject var model: DashboardModel
    /// Closes the host window. Injected because the board now lives in a
    /// standalone `NSWindow` (see `ScrumBoardWindowController`), where
    /// SwiftUI's `@Environment(\.dismiss)` has nothing to dismiss.
    var onClose: () -> Void
    @Namespace private var cardNS

    private var items: [BacklogItem] { model.sprintItems }

    /// Changes whenever any PBI's column would change — the value SwiftUI
    /// animates on, so a status flip drives the card's cross-column move.
    private var signature: String {
        items.map { "\($0.id):\($0.status ?? "")" }.joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(BoardTheme.columnBorder)
            board
            footer
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(BoardTheme.canvas)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.title3).foregroundStyle(BoardTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scrum Board").font(.headline)
                Text(model.currentSprintID ?? "no active sprint")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                LiveDot()
                Text("LIVE").font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.leading, 8)

            Spacer()

            if let r = model.lastRefresh {
                Text("updated \(Self.clock.string(from: r))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Button("Done") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: Board

    private var board: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(PipelineStage.allCases) { stage in
                    column(stage)
                }
            }
            .padding(16)
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: signature)
        }
        .overlay(alignment: .center) {
            if items.isEmpty {
                Text("No PBIs in the current sprint yet — they'll appear here\nand flow across the pipeline as the team works.")
                    .font(.callout).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func column(_ stage: PipelineStage) -> some View {
        let colItems = items.filter {
            PipelineStage.stage(for: $0, state: model.pbiStates[$0.id]) == stage
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stage.accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: stage.accent.opacity(0.7), radius: 3)
                Text(stage.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("\(colItems.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 4)

            ForEach(colItems) { item in
                BoardCard(item: item, state: model.pbiStates[item.id])
                    .matchedGeometryEffect(id: item.id, in: cardNS)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 196, alignment: .top)
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BoardTheme.column, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(BoardTheme.columnBorder, lineWidth: 1)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Cards move as `.scrum` state updates (~2s).")
            Text("◆ Developer-managed").foregroundStyle(BoardTheme.amber)
            Text("◇ SM-managed").foregroundStyle(.secondary)
            Spacer()
            Text("\(items.filter { $0.status == "done" }.count)/\(items.filter { $0.status != "cancelled" }.count) done")
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.25))
        .overlay(Divider().overlay(BoardTheme.columnBorder), alignment: .top)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

// MARK: - Card

private struct BoardCard: View {
    let item: BacklogItem
    let state: PbiState?

    private var blocked: Bool { item.status == "escalated" || item.status == "blocked" }
    private var devManaged: Bool { PBIStatus.isDevManaged(item.status ?? "") }
    private var border: Color {
        if blocked { return .red.opacity(0.65) }
        if devManaged { return BoardTheme.amber.opacity(0.5) }
        return BoardTheme.columnBorder
    }

    private var roundText: String? {
        guard let s = state else { return nil }
        var parts: [String] = []
        if let d = s.design_round, d > 0 { parts.append("d\(d)") }
        if let i = s.impl_round, i > 0 { parts.append("i\(i)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(item.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if item.kind == "docs" {
                    Text("docs").font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let r = roundText {
                    Text(r).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Text(item.title ?? "(untitled)")
                .font(.callout).lineLimit(2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                StatusBadge(status: item.status ?? "draft")
                Spacer(minLength: 0)
                if blocked {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BoardTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

// MARK: - Pipeline stages

/// The real PBI-pipeline columns, left → right in lifecycle order. The middle
/// stages mirror the Developer-managed status loop
/// (impl ⇄ pbi_review ⇄ ut_run), so the card visibly ping-pongs during review.
enum PipelineStage: String, CaseIterable, Identifiable {
    case backlog, design, implement, review, unitTests, merge, crossReview, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .design: return "Design"
        case .implement: return "Implement"
        case .review: return "PBI Review"
        case .unitTests: return "Unit Tests"
        case .merge: return "Merge"
        case .crossReview: return "Cross-Review"
        case .done: return "Done"
        }
    }

    /// Column accent — the representative status color so the dot matches the
    /// cards it holds.
    var accent: Color {
        switch self {
        case .backlog: return .gray
        case .design: return .cyan
        case .implement: return .blue
        case .review: return .blue
        case .unitTests: return .teal
        case .merge: return .purple
        case .crossReview: return .green
        case .done: return .green
        }
    }

    /// Map a PBI to its column from the top-level 13-value status. `escalated`
    /// / `blocked` have no pipeline column of their own, so fall back to the
    /// furthest stage the per-PBI pipeline state reached. `cancelled` is
    /// terminal, so it sits in the Done column (but never counts as done).
    static func stage(for item: BacklogItem, state: PbiState?) -> PipelineStage {
        switch item.status {
        case "draft", "refined": return .backlog
        case "in_progress_design": return .design
        case "in_progress_impl": return .implement
        case "in_progress_pbi_review": return .review
        case "in_progress_ut_run": return .unitTests
        case "in_progress_merge": return .merge
        case "awaiting_cross_review", "cross_review": return .crossReview
        case "done", "cancelled": return .done
        case "escalated", "blocked": return derivedStage(state)
        default: return .backlog
        }
    }

    private static func derivedStage(_ s: PbiState?) -> PipelineStage {
        guard let s else { return .backlog }
        if s.merged_sha != nil || (s.merge_failure_count ?? 0) > 0 { return .merge }
        if (s.impl_round ?? 0) > 0 || s.impl_status != nil { return .implement }
        if (s.design_round ?? 0) > 0 || s.design_status != nil { return .design }
        return .backlog
    }
}

// MARK: - Chrome

private enum BoardTheme {
    static let canvas = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let column = Color.white.opacity(0.03)
    static let columnBorder = Color.white.opacity(0.08)
    static let card = Color(red: 0.098, green: 0.098, blue: 0.110)
    static let amber = Color(red: 0.851, green: 0.467, blue: 0.024)
}

/// A softly pulsing status dot for the LIVE indicator.
private struct LiveDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.green)
            .frame(width: 7, height: 7)
            .shadow(color: .green.opacity(0.85), radius: on ? 4 : 1)
            .opacity(on ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
