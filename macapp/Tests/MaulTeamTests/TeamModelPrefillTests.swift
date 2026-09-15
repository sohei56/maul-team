//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the launch-sheet prefill precedence — `.scrum/config.json.agents`
/// over the recents cache over catalog defaults — and the coercion of choices
/// the catalog no longer allows.
final class TeamModelPrefillTests: XCTestCase {
    /// A two-provider catalog: `sm` accepts claude only (codex greyed), `rev`
    /// accepts codex only.
    private let catalog = ModelCatalog(
        providers: [
            "claude": .init(cli: "claude", materialize_frontmatter: true, efforts: ["low", "high"],
                            models: [.init(id: "opus"), .init(id: "sonnet")]),
            "codex": .init(cli: "codex", materialize_frontmatter: false, models: [.init(id: "gpt-x")]),
        ],
        seats: [
            "sm": .init(order: 1, group: "team", providers: ["claude"], phase_b_providers: ["claude", "codex"],
                        defaultChoice: ModelChoice(provider: .claude, model: "opus", effort: "high")),
            "rev": .init(order: 2, group: "team", providers: ["codex"],
                         defaultChoice: ModelChoice(provider: .codex, model: nil)),
        ],
        source: .framework)

    func testDefaultsWhenNothingSaved() {
        let r = TeamModelPrefill.resolve(saved: nil, cached: nil, catalog: catalog)
        XCTAssertEqual(r.config, catalog.defaults())
        XCTAssertTrue(r.coerced.isEmpty)
    }

    func testCacheOverridesDefaults() {
        let cached = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "sonnet")])
        let r = TeamModelPrefill.resolve(saved: nil, cached: cached, catalog: catalog)
        XCTAssertEqual(r.config["sm"], ModelChoice(provider: .claude, model: "sonnet"))
        XCTAssertEqual(r.config["rev"], ModelChoice(provider: .codex, model: nil))
        XCTAssertTrue(r.coerced.isEmpty)
    }

    func testConfigOverridesCache() {
        let cached = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "sonnet")])
        let saved = TeamModelConfig(choices: [
            "sm": ModelChoice(provider: .claude, model: "opus", effort: "low"),
            "rev": ModelChoice(provider: .codex, model: "gpt-x"),
        ])
        let r = TeamModelPrefill.resolve(saved: saved, cached: cached, catalog: catalog)
        XCTAssertEqual(r.config["sm"], ModelChoice(provider: .claude, model: "opus", effort: "low"))
        XCTAssertEqual(r.config["rev"]?.model, "gpt-x")
    }

    func testDisallowedProviderIsCoercedToDefault() {
        let saved = TeamModelConfig(choices: ["sm": ModelChoice(provider: .codex, model: "gpt-x")])
        let r = TeamModelPrefill.resolve(saved: saved, cached: nil, catalog: catalog)
        XCTAssertEqual(r.config["sm"], catalog.defaultChoice(for: "sm"))
        XCTAssertEqual(r.coerced, ["sm"])
    }

    func testInvalidModelTokenIsCoerced() {
        let cached = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "bad token")])
        let r = TeamModelPrefill.resolve(saved: nil, cached: cached, catalog: catalog)
        XCTAssertEqual(r.config["sm"], catalog.defaultChoice(for: "sm"))
        XCTAssertEqual(r.coerced, ["sm"])
    }

    func testUnknownEffortIsCoerced() {
        let saved = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "opus", effort: "ultra")])
        let r = TeamModelPrefill.resolve(saved: saved, cached: nil, catalog: catalog)
        XCTAssertEqual(r.coerced, ["sm"])
    }

    func testCustomModelIdSurvives() {
        let saved = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "claude-opus-4/latest")])
        let r = TeamModelPrefill.resolve(saved: saved, cached: nil, catalog: catalog)
        XCTAssertEqual(r.config["sm"]?.model, "claude-opus-4/latest")
        XCTAssertTrue(r.coerced.isEmpty)
    }

    func testSeatsOutsideCatalogAreDropped() {
        let saved = TeamModelConfig(choices: ["ghost": ModelChoice(provider: .claude, model: "opus")])
        let r = TeamModelPrefill.resolve(saved: saved, cached: nil, catalog: catalog)
        XCTAssertNil(r.config["ghost"])
        XCTAssertEqual(r.config.choices.count, 2)
        XCTAssertTrue(r.coerced.isEmpty)
    }

    func testProjectOverloadUsesCacheWhenNoConfigFile() {
        let missing = NSTemporaryDirectory() + "maul-prefill-\(UUID().uuidString)"
        let cached = TeamModelConfig(choices: ["sm": ModelChoice(provider: .claude, model: "sonnet")])
        let project = Project(path: missing, lastOpened: Date(), teamModels: cached)
        let r = TeamModelPrefill.resolve(project: project, catalog: catalog)
        XCTAssertEqual(r.config["sm"]?.model, "sonnet")
    }
}
