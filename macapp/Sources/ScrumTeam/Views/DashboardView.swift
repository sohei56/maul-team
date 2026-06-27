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
        ScrollView {
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
                pbiBoard
                if model.testResults != nil { integrationCard }
            }
            .padding(12)
        }
        .textSelection(.enabled)
        .sheet(item: $selected) { item in
            PBIDetailView(item: item, pbiState: model.pbiStates[item.id])
        }
    }

    // MARK: Project

    private var projectCard: some View {
        SectionCard(title: "Project", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.state?.product_goal ?? model.backlog?.product_goal ?? "No product goal")
                    .font(.body)
                if let phase = model.state?.phase {
                    HStack(spacing: 6) {
                        Text("Phase").font(.caption).foregroundStyle(.secondary)
                        Text(phaseLabel(phase))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    // MARK: Sprint

    private var sprintCard: some View {
        SectionCard(title: "Sprint", systemImage: "flag.checkered") {
            if let sprint = model.sprint {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(sprint.id ?? "—").font(.headline)
                        if let st = sprint.status {
                            Text(st).font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    Text(sprint.goal ?? "No goal").font(.subheadline).foregroundStyle(.secondary)

                    let total = model.sprintItems.count
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
            } else {
                Text("No active sprint").foregroundStyle(.secondary).font(.subheadline)
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

                if items.isEmpty {
                    Text(pbiScope == .current ? "No PBIs in the current sprint" : "No PBIs")
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
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
    }

    private func phaseLabel(_ phase: String) -> String {
        [
            "new": "New", "requirements_sprint": "Requirements",
            "backlog_created": "Backlog Created", "sprint_planning": "Sprint Planning",
            "pbi_pipeline_active": "PBI Pipelines Running", "review": "Review",
            "sprint_review": "Sprint Review", "retrospective": "Retrospective",
            "integration_sprint": "Integration", "complete": "Complete",
        ][phase] ?? phase
    }
}
