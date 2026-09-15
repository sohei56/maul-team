//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

// MARK: - Identifiers

/// A provider id from the model catalog (`claude`, `codex`, …). String-backed
/// so a provider added to the catalog later decodes without an app update.
struct ProviderID: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let claude = ProviderID("claude")
    static let codex = ProviderID("codex")
}

/// A seat id from the model catalog — the key of `seats`, of the
/// `--agent-model <seat>=…` flag, and of `.scrum/config.json.agents`.
struct AgentSeat: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let scrumMaster = AgentSeat("scrum-master")
    static let productOwner = AgentSeat("product-owner")
}

// MARK: - ModelChoice

/// One seat's provider + model (+ effort) selection. `model == nil` means "the
/// provider CLI's own default" (the catalog spells it `null`; the launch flag
/// spells it `<provider>:default`).
struct ModelChoice: Hashable, Codable {
    var provider: ProviderID
    var model: String?
    var effort: String?

    init(provider: ProviderID, model: String? = nil, effort: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    /// The `--agent-model` value: `provider:model[@effort]`, with a nil model
    /// rendered as `default`.
    var flagValue: String {
        var out = provider.rawValue + ":" + (model ?? "default")
        if let effort, !effort.isEmpty { out += "@" + effort }
        return out
    }

    /// Mirrors the framework's `is_safe_model_token` (bash
    /// `^[A-Za-z0-9][A-Za-z0-9._/-]*$`): non-empty, first character an ASCII
    /// letter or digit, the rest ASCII letters/digits or `.` `_` `/` `-`.
    /// Written as explicit character checks — not a regex literal — so the
    /// accepted set is visible here and pinned by ModelChoiceTests.
    static func isValidModelToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard let first = scalars.first, isASCIIAlphanumeric(first) else { return false }
        for scalar in scalars.dropFirst() {
            if isASCIIAlphanumeric(scalar) { continue }
            switch scalar {
            case ".", "_", "/", "-": continue
            default: return false
            }
        }
        return true
    }

    private static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
    }
}

// MARK: - TeamModelConfig

/// The per-seat table: seat id → choice. Encodes as the bare dictionary so it
/// is shaped exactly like `.scrum/config.json.agents`.
struct TeamModelConfig: Hashable, Codable {
    var choices: [String: ModelChoice]

    init(choices: [String: ModelChoice] = [:]) { self.choices = choices }

    init(from decoder: Decoder) throws {
        choices = try decoder.singleValueContainer().decode([String: ModelChoice].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(choices)
    }

    var isEmpty: Bool { choices.isEmpty }

    subscript(seat: String) -> ModelChoice? {
        get { choices[seat] }
        set { choices[seat] = newValue }
    }

    /// `base` with this config's seats laid over it (self wins per seat).
    func merging(over base: TeamModelConfig) -> TeamModelConfig {
        TeamModelConfig(choices: base.choices.merging(choices) { _, mine in mine })
    }

    /// Only the seats named in `seats`, in no particular order.
    func filtered(to seats: [String]) -> TeamModelConfig {
        TeamModelConfig(choices: choices.filter { seats.contains($0.key) })
    }
}

// MARK: - ModelCatalog

/// `docs/contracts/model-catalog.json` — the framework/app contract for seat
/// membership, per-seat defaults, and advisory model menus. Decoded leniently
/// (every field optional) so a newer catalog still loads; `parse` only rejects
/// a document with no usable `seats`.
struct ModelCatalog: Codable {
    struct Model: Codable, Hashable, Identifiable {
        var id: String
        var label: String?

        init(id: String, label: String? = nil) { self.id = id; self.label = label }

        var displayName: String { label ?? id }
    }

    struct Provider: Codable {
        var label: String?
        var cli: String?
        var materialize_frontmatter: Bool?
        var efforts: [String]?
        var models: [Model]?

        init(label: String? = nil, cli: String? = nil, materialize_frontmatter: Bool? = nil,
             efforts: [String]? = nil, models: [Model]? = nil) {
            self.label = label; self.cli = cli
            self.materialize_frontmatter = materialize_frontmatter
            self.efforts = efforts; self.models = models
        }
    }

    struct Seat: Codable {
        var order: Int?
        var group: String?
        var label: String?
        var short_label: String?
        var agents: [String]?
        var providers: [String]?
        var phase_b_providers: [String]?
        var defaultChoice: ModelChoice?

        enum CodingKeys: String, CodingKey {
            case order, group, label, short_label, agents, providers, phase_b_providers
            case defaultChoice = "default"
        }

        init(order: Int? = nil, group: String? = nil, label: String? = nil, short_label: String? = nil,
             agents: [String]? = nil, providers: [String]? = nil, phase_b_providers: [String]? = nil,
             defaultChoice: ModelChoice? = nil) {
            self.order = order; self.group = group; self.label = label; self.short_label = short_label
            self.agents = agents; self.providers = providers; self.phase_b_providers = phase_b_providers
            self.defaultChoice = defaultChoice
        }
    }

    /// Where the catalog came from. Decides the launch flag style: a framework
    /// catalog means `--agent-model` is understood; the builtin fallback means
    /// an older framework that only knows `--sm-model`/`--po-model`.
    enum Source { case framework, builtin }

    var schema_version: Int?
    var providers: [String: Provider]?
    var seats: [String: Seat]?
    var excluded_agents: [String]?

    /// Not part of the JSON — set by `load`.
    var source: Source = .builtin

    enum CodingKeys: String, CodingKey {
        case schema_version, providers, seats, excluded_agents
    }

    init(schema_version: Int? = nil, providers: [String: Provider]? = nil,
         seats: [String: Seat]? = nil, excluded_agents: [String]? = nil, source: Source = .builtin) {
        self.schema_version = schema_version
        self.providers = providers
        self.seats = seats
        self.excluded_agents = excluded_agents
        self.source = source
    }

    static let teamGroup = "team"
    static let pipelineGroup = "pipeline"

    // MARK: Seats

    /// Every seat ordered by `order` (unordered seats last, then by id).
    var seatsOrdered: [(id: String, seat: Seat)] {
        (seats ?? [:])
            .map { (id: $0.key, seat: $0.value) }
            .sorted {
                let a = $0.seat.order ?? Int.max, b = $1.seat.order ?? Int.max
                return a != b ? a < b : $0.id < $1.id
            }
    }

    /// Seat ids in catalog order — the order the launch flags are emitted in.
    var seatOrder: [String] { seatsOrdered.map(\.id) }

    func seats(in group: String) -> [(id: String, seat: Seat)] {
        seatsOrdered.filter { $0.seat.group == group }
    }

    func seat(_ id: String) -> Seat? { seats?[id] }

    /// Providers the framework accepts for this seat today.
    func allowedProviders(for seat: String) -> [ProviderID] {
        (seats?[seat]?.providers ?? []).map { ProviderID($0) }
    }

    /// Providers the UI renders for this seat (`phase_b_providers`, falling
    /// back to `providers`); those outside `allowedProviders` are greyed.
    func displayProviders(for seat: String) -> [ProviderID] {
        let s = seats?[seat]
        return (s?.phase_b_providers ?? s?.providers ?? []).map { ProviderID($0) }
    }

    // MARK: Providers

    func provider(_ id: ProviderID) -> Provider? { providers?[id.rawValue] }

    func providerLabel(_ id: ProviderID) -> String {
        providers?[id.rawValue]?.label ?? id.rawValue
    }

    /// The executable the provider needs on PATH (`cli`, else the provider id).
    func cliName(for id: ProviderID) -> String {
        providers?[id.rawValue]?.cli ?? id.rawValue
    }

    func models(for provider: ProviderID) -> [Model] {
        providers?[provider.rawValue]?.models ?? []
    }

    func efforts(for provider: ProviderID) -> [String] {
        providers?[provider.rawValue]?.efforts ?? []
    }

    /// True when a nil model is meaningful for this provider — its CLI runs
    /// its own default instead of a value the framework must materialize into
    /// agent frontmatter (`materialize_frontmatter: false`, e.g. codex).
    func allowsCLIDefault(for provider: ProviderID) -> Bool {
        providers?[provider.rawValue]?.materialize_frontmatter == false
    }

    // MARK: Defaults & validation

    /// One choice per seat, from each seat's `default`. A seat without one
    /// falls back to its first allowed provider with no model.
    func defaults() -> TeamModelConfig {
        var out: [String: ModelChoice] = [:]
        for (id, seat) in seatsOrdered {
            out[id] = seat.defaultChoice
                ?? ModelChoice(provider: allowedProviders(for: id).first ?? .claude)
        }
        return TeamModelConfig(choices: out)
    }

    /// The seat's default, or a nil-model choice of its first allowed provider.
    func defaultChoice(for seat: String) -> ModelChoice {
        seats?[seat]?.defaultChoice
            ?? ModelChoice(provider: allowedProviders(for: seat).first ?? .claude)
    }

    /// Why a choice cannot be launched for a seat, or nil when it can.
    func validationProblem(_ choice: ModelChoice, for seat: String) -> String? {
        if !allowedProviders(for: seat).contains(choice.provider) {
            return "provider \(choice.provider.rawValue) is not available for this seat"
        }
        if let model = choice.model {
            if !ModelChoice.isValidModelToken(model) {
                return "model id must match [A-Za-z0-9][A-Za-z0-9._/-]*"
            }
        } else if !allowsCLIDefault(for: choice.provider) {
            return "a model id is required"
        }
        if let effort = choice.effort, !effort.isEmpty {
            let allowed = efforts(for: choice.provider)
            if !allowed.contains(effort) {
                return "effort must be one of \(allowed.joined(separator: ", "))"
            }
        }
        return nil
    }

    /// Catalog seats whose choice in `config` cannot be launched (missing
    /// seats are not reported — the caller prefills every seat first).
    func invalidSeats(in config: TeamModelConfig) -> [String] {
        seatOrder.filter { seat in
            guard let choice = config[seat] else { return false }
            return validationProblem(choice, for: seat) != nil
        }
    }

    // MARK: Loading

    static let relativePath = "docs/contracts/model-catalog.json"

    /// The framework's catalog, else the builtin fallback for a framework
    /// checkout that predates the catalog (launch then uses the legacy flags).
    static func load(frameworkPath: String) -> ModelCatalog {
        let url = URL(fileURLWithPath: frameworkPath).appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url), var catalog = parse(data) else {
            return .builtin
        }
        catalog.source = .framework
        return catalog
    }

    /// nil when the data is not a catalog document or names no seats.
    static func parse(_ data: Data) -> ModelCatalog? {
        guard let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data),
              let seats = catalog.seats, !seats.isEmpty
        else { return nil }
        return catalog
    }

    /// Claude-only fallback used when the framework ships no catalog: the two
    /// seats the legacy `--sm-model`/`--po-model` flags can set, with the
    /// four model aliases those flags accepted and no effort control.
    static let builtin = ModelCatalog(
        schema_version: 1,
        providers: [
            "claude": Provider(
                label: "Claude Code", cli: "claude", materialize_frontmatter: true,
                models: [
                    Model(id: "opus", label: "Opus (alias)"),
                    Model(id: "fable", label: "Fable (alias)"),
                    Model(id: "sonnet", label: "Sonnet (alias)"),
                    Model(id: "haiku", label: "Haiku (alias)"),
                ]),
        ],
        seats: [
            "scrum-master": Seat(
                order: 1, group: teamGroup, label: "Scrum Master", short_label: "SM",
                agents: ["scrum-master"], providers: ["claude"],
                defaultChoice: ModelChoice(provider: .claude, model: "opus")),
            "product-owner": Seat(
                order: 2, group: teamGroup, label: "Product Owner (agent)", short_label: "PO",
                agents: ["product-owner"], providers: ["claude"],
                defaultChoice: ModelChoice(provider: .claude, model: "opus")),
        ],
        excluded_agents: [],
        source: .builtin)
}

// MARK: - Prefill

/// Computes what the launch sheet shows for a project.
enum TeamModelPrefill {
    /// Precedence per seat: `.scrum/config.json.agents` (what the framework
    /// last ran) > the `Project.teamModels` cache in recents > catalog
    /// defaults. A saved choice the catalog no longer allows (provider not
    /// permitted for the seat, malformed model id, bad effort) is replaced by
    /// the seat default and reported in `coerced` so the UI can say so.
    static func resolve(project: Project, catalog: ModelCatalog) -> (config: TeamModelConfig, coerced: Set<String>) {
        resolve(
            saved: ScrumConfigReader.read(projectPath: project.path),
            cached: project.teamModels,
            catalog: catalog)
    }

    static func resolve(saved: TeamModelConfig?, cached: TeamModelConfig?, catalog: ModelCatalog)
        -> (config: TeamModelConfig, coerced: Set<String>)
    {
        var merged = catalog.defaults()
        if let cached { merged = cached.merging(over: merged) }
        if let saved { merged = saved.merging(over: merged) }

        var coerced: Set<String> = []
        var out = TeamModelConfig()
        for seat in catalog.seatOrder {
            let choice = merged[seat] ?? catalog.defaultChoice(for: seat)
            if catalog.validationProblem(choice, for: seat) == nil {
                out[seat] = choice
            } else {
                let fallback = catalog.defaultChoice(for: seat)
                out[seat] = fallback
                if choice != fallback { coerced.insert(seat) }
            }
        }
        return (out, coerced)
    }
}
