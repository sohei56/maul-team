//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// Native project dashboard (right pane): project/sprint overview, the PBI
/// board (click a PBI for details), and Integration Sprint test results.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var selected: BacklogItem?
    @State private var pbiScope: PBIScope = .current

    enum PBIScope: String, CaseIterable, Identifiable {
        case current = "Current", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        // Project/sprint stay pinned; only the PBI board (and the
        // integration card that trails it) scroll below them.
        VStack(alignment: .leading, spacing: 12) {
            if let r = model.lastRefresh {
                HStack {
                    Spacer()
                    Text("as of \(Self.clock.string(from: r))")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            projectCard
            sprintCard
            // PBI board fills the remaining height; its picker + buttons are a
            // fixed header and only the PBI rows scroll (see `pbiBoard`).
            pbiBoard
            // Release-stage phases fold these results into sprintCard;
            // show the standalone card only outside those phases (e.g. a
            // backlog_created defect-fix loop after a failed run).
            if model.testResults != nil && !releaseStage { integrationCard }
        }
        .padding(12)
        .textSelection(.enabled)
        .sheet(item: $selected) { item in
            PBIDetailView(item: item, pbiState: model.pbiStates[item.id])
        }
    }

    // MARK: Project

    private var projectCard: some View {
        SectionCard(title: "Project", systemImage: "shippingbox") {
            Text(model.state?.product_goal ?? model.backlog?.product_goal ?? "No product goal")
                .font(.body)
        }
    }

    // MARK: Sprint

    /// True while the project is in a post-development release stage
    /// (Integration Sprint / UAT & Release). In these phases the last dev
    /// Sprint is already `complete` and the **phase** is the protagonist —
    /// so the Sprint panel flips to a stage view and the standalone
    /// Integration results card is folded into it.
    private var releaseStage: Bool {
        let phase = model.state?.phase
        return phase == "integration_sprint" || phase == "uat_release"
    }

    private var sprintCard: some View {
        let phase = model.state?.phase
        return SectionCard(
            title: releaseStage ? stageTitle(phase) : "Sprint",
            systemImage: releaseStage ? stageIcon(phase) : "flag.checkered"
        ) {
            if releaseStage, let phase {
                releaseStageBody(phase: phase)
            } else if let sprint = model.sprint {
                developmentSprintBody(sprint)
            } else {
                noSprintBody
            }
        }
    }

    private func stageTitle(_ phase: String?) -> String {
        phase == "uat_release" ? "UAT & Release" : "Integration Sprint"
    }

    private func stageIcon(_ phase: String?) -> String {
        phase == "uat_release" ? "shippingbox" : "testtube.2"
    }

    /// Semantic color for a raw `sprint.status` value. Replaces the previous
    /// hardcoded green, which mislabeled `failed` and `planning`.
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "complete": return .green
        case "failed": return .red
        case "planning": return .gray
        default: return .blue  // active, cross_review, sprint_review
        }
    }

    /// Release-stage view: the phase is the headline; the closed dev Sprint
    /// recedes to a context line; the Integration test results are inlined.
    @ViewBuilder
    private func releaseStageBody(phase: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(phaseLabel(phase)).font(.headline)
                Text("ACTIVE").font(.caption.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                Spacer()
            }
            if let sid = model.sprint?.id {
                Text("following \(sid) · closed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let total = model.deliverableCount
            if total > 0 {
                Text("\(model.doneCount)/\(total) PBIs delivered")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.testResults != nil {
                Divider()
                integrationResults
            }
        }
    }

    @ViewBuilder
    private func developmentSprintBody(_ sprint: Sprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(sprint.id ?? "—").font(.headline)
                if let st = sprint.status {
                    Text(st).font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(statusColor(st).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(st))
                }
                if let phase = model.state?.phase {
                    HStack(spacing: 4) {
                        Text("Phase").font(.caption2).foregroundStyle(.secondary)
                        Text(phaseLabel(phase))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
            }
            Text(sprint.goal ?? "No goal").font(.subheadline).foregroundStyle(.secondary)

            let total = model.deliverableCount
            let done = model.doneCount
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(done)/\(total) PBIs done").font(.caption)
                    Spacer()
                }
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
            }

            if let devs = sprint.developers, !devs.isEmpty {
                let names = devs.map { $0.id }.joined(separator: ", ")
                Label(names, systemImage: "person.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var noSprintBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No active sprint").foregroundStyle(.secondary).font(.subheadline)
            if let phase = model.state?.phase {
                HStack(spacing: 4) {
                    Text("Phase").font(.caption2).foregroundStyle(.secondary)
                    Text(phaseLabel(phase))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: PBI board

    private var pbiBoard: some View {
        let items = pbiScope == .current ? model.sprintItems : model.allItems
        return SectionCard(title: "PBI Board", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $pbiScope) {
                    Text("Current (\(model.sprintItems.count))").tag(PBIScope.current)
                    Text("All (\(model.allItems.count))").tag(PBIScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    ScrumBoardWindowController.shared.open(model: model)
                } label: {
                    Label("Open Scrum Board", systemImage: "rectangle.split.3x1")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Live pipeline board — watch the current sprint's PBIs move across stages in real time")

                if items.isEmpty {
                    Text(pbiScope == .current ? "No PBIs in the current sprint" : "No PBIs")
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
                    // Only the rows scroll; the picker + buttons above stay put.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                pbiRow(item)
                                if item.id != items.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pbiRow(_ item: BacklogItem) -> some View {
        let st = model.pbiStates[item.id]
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(item.sprint_id ?? "backlog")
                        .font(.caption2)
                        .foregroundStyle(item.sprint_id == model.currentSprintID ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    if item.kind == "docs" {
                        Text("docs").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(item.title ?? "(untitled)").font(.callout).lineLimit(1)
                    .textSelection(.disabled)   // list row navigates on tap; don't select the title text
                if let updated = updatedText(item, st) {
                    Text("updated \(updated)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let round = roundText(item, st) {
                Text(round).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            StatusBadge(status: item.status ?? "draft")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { selected = item }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Per-PBI updated timestamp (pipeline state preferred, else backlog item).
    private func updatedText(_ item: BacklogItem, _ st: PbiState?) -> String? {
        let raw = st?.updated_at ?? item.updated_at
        guard let raw, !raw.isEmpty else { return nil }
        return DashboardModel.shortTime(raw)
    }

    /// Surface the relevant round counter for live dev-managed PBIs.
    private func roundText(_ item: BacklogItem, _ st: PbiState?) -> String? {
        guard let st, let status = item.status, PBIStatus.isDevManaged(status) else { return nil }
        if status == "in_progress_design" { return "d\(st.design_round ?? 0)" }
        return "i\(st.impl_round ?? 0)"
    }

    // MARK: Integration results

    private var integrationCard: some View {
        SectionCard(title: "Integration Sprint", systemImage: "testtube.2") {
            integrationResults
        }
    }

    /// Integration test results body, shared by the standalone
    /// `integrationCard` and the folded-in release-stage `sprintCard`.
    @ViewBuilder
    private var integrationResults: some View {
        let tr = model.testResults
        VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Overall").font(.caption).foregroundStyle(.secondary)
                    ResultBadge(status: tr?.overall_status ?? "—")
                    Spacer()
                }
                ForEach(tr?.categories ?? []) { cat in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(cat.name).font(.callout)
                            Spacer()
                            if let total = cat.total {
                                Text("\(cat.passed ?? 0)/\(total)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            ResultBadge(status: cat.status ?? "—")
                        }
                        if cat.status == "skipped", let reason = cat.reason {
                            Text(reason).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let errs = cat.errors, !errs.isEmpty {
                            Text(errs.prefix(3).joined(separator: "\n"))
                                .font(.caption2.monospaced()).foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                    if cat.id != tr?.categories?.last?.id { Divider() }
                }
            }
    }

    private func phaseLabel(_ phase: String) -> String {
        [
            "new": "New", "requirements_sprint": "Requirement Definition",
            "backlog_created": "Backlog Created", "sprint_planning": "Sprint Planning",
            "pbi_pipeline_active": "PBI Development", "review": "Cross Review",
            "sprint_review": "Sprint Review", "retrospective": "Retrospective",
            "integration_sprint": "Integration Tests", "uat_release": "UAT & Release",
            "complete": "Complete",
        ][phase] ?? phase
    }
}
