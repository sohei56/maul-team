//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// The "Team models" block of the launch sheet: one row per catalog seat with
/// a provider toggle, a model menu (catalog models + Custom…) and, where the
/// provider defines efforts, an effort menu. Team seats are always visible;
/// pipeline sub-agent seats fold into a disclosure group.
struct TeamModelsSection: View {
    let catalog: ModelCatalog
    let mode: LaunchMode
    let coercedSeats: Set<String>
    @Binding var config: TeamModelConfig

    /// CLI name → found on the login shell's PATH. Absent until probed.
    @State private var cliFound: [String: Bool] = [:]
    @State private var pipelineExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Team models", systemImage: "cpu").font(.headline)
                Spacer()
                Button("Reset to defaults") { config = catalog.defaults() }
                    .controlSize(.small)
            }

            if catalog.source == .builtin {
                note("This framework ships no model catalog — only the Scrum Master "
                     + "(and, in Autonomous mode, the Product Owner) model is passed, "
                     + "via the legacy --sm-model/--po-model flags.",
                     icon: "info.circle", color: .secondary)
            }

            if !coercedSeats.isEmpty {
                let names = catalog.seatOrder.filter(coercedSeats.contains)
                    .map { catalog.seat($0)?.short_label ?? $0 }
                note("Saved choices for \(names.joined(separator: ", ")) are no longer "
                     + "allowed and were reset to the defaults.",
                     icon: "arrow.uturn.backward.circle", color: .orange)
            }

            cliWarnings

            VStack(alignment: .leading, spacing: 8) {
                ForEach(catalog.seats(in: ModelCatalog.teamGroup), id: \.id) { entry in
                    SeatRow(seatID: entry.id, seat: entry.seat, catalog: catalog, mode: mode,
                            choice: binding(for: entry.id))
                }
            }

            let pipeline = catalog.seats(in: ModelCatalog.pipelineGroup)
            if !pipeline.isEmpty {
                DisclosureGroup("Pipeline sub-agents", isExpanded: $pipelineExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(pipeline, id: \.id) { entry in
                            SeatRow(seatID: entry.id, seat: entry.seat, catalog: catalog, mode: mode,
                                    choice: binding(for: entry.id))
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
        .task(id: probeTargets) { await probe() }
    }

    private func binding(for seat: String) -> Binding<ModelChoice> {
        Binding(
            get: { config[seat] ?? catalog.defaultChoice(for: seat) },
            set: { config[seat] = $0 })
    }

    // MARK: CLI availability

    /// The CLIs worth checking: every provider the catalog can offer a seat.
    private var probeTargets: [String] {
        var seen: [String] = []
        for seat in catalog.seatOrder {
            for provider in catalog.displayProviders(for: seat) {
                let cli = catalog.cliName(for: provider)
                if !seen.contains(cli) { seen.append(cli) }
            }
        }
        return seen
    }

    private func probe() async {
        for cli in probeTargets {
            let found = await CLIProbe.locate(cli) != nil
            cliFound[cli] = found
        }
    }

    @ViewBuilder
    private var cliWarnings: some View {
        ForEach(probeTargets, id: \.self) { cli in
            if cliFound[cli] == false {
                if cli == catalog.cliName(for: .claude) {
                    note("`\(cli)` was not found on your PATH — the launch will abort.",
                         icon: "xmark.octagon.fill", color: .red)
                } else {
                    note("`\(cli)` was not found on your PATH — seats on this provider "
                         + "cannot run; the launch proceeds without them.",
                         icon: "exclamationmark.triangle.fill", color: .orange)
                }
            }
        }
    }

    private func note(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.caption).foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Seat row

private struct SeatRow: View {
    let seatID: String
    let seat: ModelCatalog.Seat
    let catalog: ModelCatalog
    let mode: LaunchMode
    @Binding var choice: ModelChoice

    private static let labelWidth: CGFloat = 168
    private static let defaultTag = ""
    private static let customTag = "\u{1}custom"

    private var models: [ModelCatalog.Model] { catalog.models(for: choice.provider) }
    private var efforts: [String] { catalog.efforts(for: choice.provider) }
    private var allowsDefault: Bool { catalog.allowsCLIDefault(for: choice.provider) }
    private var problem: String? { catalog.validationProblem(choice, for: seatID) }

    /// True when the model is not one the menu offers — shown as a text field.
    private var isCustom: Bool {
        guard let model = choice.model else { return !allowsDefault }
        return !models.contains { $0.id == model }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(seat.label ?? seatID)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .lineLimit(1)
                    .help(seatID)
                providerToggles
                modelPicker.frame(width: 190)
                if !efforts.isEmpty {
                    effortPicker.frame(width: 110)
                }
                Spacer(minLength: 0)
            }
            if isCustom {
                HStack(spacing: 8) {
                    Spacer().frame(width: Self.labelWidth)
                    TextField("model id", text: customText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 260)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(problem == nil ? Color.clear : Color.red, lineWidth: 1.5))
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            if seatID == AgentSeat.productOwner.rawValue && mode == .normal {
                Text("PO teammate is spawned only in Autonomous mode — in Normal mode you fill this seat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, Self.labelWidth + 8)
            }
        }
    }

    // MARK: Provider

    private var providerToggles: some View {
        HStack(spacing: 2) {
            ForEach(catalog.displayProviders(for: seatID), id: \.rawValue) { provider in
                let allowed = catalog.allowedProviders(for: seatID).contains(provider)
                let selected = choice.provider == provider
                Button { select(provider) } label: {
                    Text(shortName(provider))
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear),
                            in: Capsule())
                        .overlay(Capsule().strokeBorder(
                            selected ? Color.accentColor : Color(nsColor: .separatorColor)))
                }
                .buttonStyle(.plain)
                .disabled(!allowed)
                .help(allowed ? catalog.providerLabel(provider) : "Available in a later release")
            }
        }
    }

    private func shortName(_ provider: ProviderID) -> String {
        provider.rawValue.prefix(1).uppercased() + provider.rawValue.dropFirst()
    }

    /// Switching provider restores the seat default when it is on that
    /// provider; otherwise the provider's first model (or its CLI default).
    private func select(_ provider: ProviderID) {
        guard provider != choice.provider else { return }
        let seatDefault = catalog.defaultChoice(for: seatID)
        if seatDefault.provider == provider {
            choice = seatDefault
        } else {
            let model = catalog.allowsCLIDefault(for: provider) ? nil : catalog.models(for: provider).first?.id
            choice = ModelChoice(provider: provider, model: model, effort: nil)
        }
    }

    // MARK: Model

    private var modelPicker: some View {
        Picker("", selection: modelSelection) {
            if allowsDefault {
                Text(choice.provider == .codex ? "(Codex default)" : "(\(shortName(choice.provider)) default)")
                    .tag(Self.defaultTag)
            }
            ForEach(models) { model in
                Text(model.displayName).tag(model.id)
            }
            Divider()
            Text("Custom…").tag(Self.customTag)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                guard let model = choice.model else { return allowsDefault ? Self.defaultTag : Self.customTag }
                return models.contains { $0.id == model } ? model : Self.customTag
            },
            set: { tag in
                switch tag {
                case Self.defaultTag: choice.model = nil
                case Self.customTag: if !isCustom { choice.model = "" }
                default: choice.model = tag
                }
            })
    }

    private var customText: Binding<String> {
        Binding(get: { choice.model ?? "" }, set: { choice.model = $0 })
    }

    // MARK: Effort

    private var effortPicker: some View {
        Picker("", selection: effortSelection) {
            Text("effort: default").tag("")
            ForEach(efforts, id: \.self) { Text("effort: \($0)").tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var effortSelection: Binding<String> {
        Binding(
            get: { choice.effort ?? "" },
            set: { choice.effort = $0.isEmpty ? nil : $0 })
    }
}
