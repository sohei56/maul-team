import SwiftUI

/// PBI detail sheet: backlog item fields + per-PBI pipeline state.
struct PBIDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: BacklogItem
    let pbiState: PbiState?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overview
                    if let ac = item.acceptance_criteria, !ac.isEmpty { acceptanceCriteria(ac) }
                    pipeline
                    references
                }
                .padding(16)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .frame(idealWidth: 560, idealHeight: 620)
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.id).font(.headline.monospaced()).foregroundStyle(.secondary)
            StatusBadge(status: item.status ?? "draft")
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title ?? "(untitled)").font(.title3.weight(.semibold))
            if let d = item.description, !d.isEmpty {
                Text(d).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let p = item.priority { field("Priority", "\(p)") }
                if let s = item.sprint_id { field("Sprint", s) }
                if let imp = item.implementer_id { field("Implementer", imp) }
                field("Kind", item.kind ?? "code")
            }
            .padding(.top, 2)
            if let deps = item.depends_on_pbi_ids, !deps.isEmpty {
                field("Depends on", deps.joined(separator: ", "))
            }
        }
    }

    private func acceptanceCriteria(_ ac: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Acceptance Criteria")
            ForEach(Array(ac.enumerated()), id: \.offset) { _, c in
                Label(c, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var pipeline: some View {
        if let st = pbiState {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Pipeline State")
                HStack(spacing: 14) {
                    field("Design round", "\(st.design_round ?? 0)")
                    field("Impl round", "\(st.impl_round ?? 0)")
                }
                if let branch = st.branch { field("Branch", branch) }
                if let wt = st.worktree { field("Worktree", wt) }
                if let mf = st.merge_failure_count, mf > 0 { field("Merge failures", "\(mf)") }
                if let er = st.escalation_reason, !er.isEmpty {
                    field("Escalation", er).foregroundStyle(.red)
                }
                if let merged = st.merged_sha { field("Merged", String(merged.prefix(10))) }
            }
        }
    }

    @ViewBuilder
    private var references: some View {
        let docs = item.design_doc_paths ?? []
        let paths = item.paths_touched ?? pbiState?.paths_touched ?? []
        if !docs.isEmpty || !paths.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("References")
                if !docs.isEmpty { field("Design docs", docs.joined(separator: "\n")) }
                if !paths.isEmpty { field("Paths touched", paths.joined(separator: "\n")) }
            }
        }
    }

    // MARK: helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
        }
    }
}
