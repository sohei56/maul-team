//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the app's reading of `docs/contracts/model-catalog.json`: the real
/// file decodes into the seat/provider shape the launch sheet and launcher
/// use, unknown/missing fields are tolerated, and the builtin fallback is
/// self-consistent.
final class ModelCatalogTests: XCTestCase {
    /// The repo root, walked up from this file (macapp/Tests/MaulTeamTests/).
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MaulTeamTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macapp
        .deletingLastPathComponent()   // repo

    private func realCatalog() throws -> ModelCatalog {
        let url = Self.repoRoot.appendingPathComponent(ModelCatalog.relativePath)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(ModelCatalog.parse(data), "catalog at \(url.path) must parse")
    }

    // MARK: Real catalog

    func testRealCatalogDecodesNineSeatsInOrder() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.seatOrder, [
            "scrum-master", "product-owner", "requirements-analyst", "developer",
            "codex-reviewers", "pbi-designer", "pbi-implementer", "pbi-ut-author",
            "integrity-reviewers",
        ])
        XCTAssertEqual(catalog.seats(in: ModelCatalog.teamGroup).count, 5)
        XCTAssertEqual(catalog.seats(in: ModelCatalog.pipelineGroup).count, 4)
        XCTAssertEqual(catalog.excluded_agents, ["scrum-explorer", "ceremony-operator"])
    }

    func testRealCatalogProvidersAndDefaults() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.efforts(for: .claude), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(catalog.efforts(for: .codex), [])
        XCTAssertTrue(catalog.models(for: .claude).map(\.id).contains("opus"))
        XCTAssertTrue(catalog.models(for: .codex).map(\.id).contains("gpt-5.6-luna"))
        XCTAssertEqual(catalog.cliName(for: .codex), "codex")
        XCTAssertFalse(catalog.allowsCLIDefault(for: .claude))
        XCTAssertTrue(catalog.allowsCLIDefault(for: .codex))

        let defaults = catalog.defaults()
        XCTAssertEqual(defaults["scrum-master"], ModelChoice(provider: .claude, model: "opus", effort: "high"))
        XCTAssertEqual(defaults["developer"], ModelChoice(provider: .claude, model: "sonnet", effort: "high"))
        XCTAssertEqual(defaults["codex-reviewers"], ModelChoice(provider: .codex, model: nil, effort: nil))
        XCTAssertEqual(defaults.choices.count, 9)
    }

    func testRealCatalogPhaseBProvidersAreDisplayedButNotAllowed() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.displayProviders(for: "scrum-master"), [.claude, .codex])
        XCTAssertEqual(catalog.allowedProviders(for: "scrum-master"), [.claude])
        XCTAssertEqual(catalog.displayProviders(for: "developer"), [.claude])
        XCTAssertEqual(catalog.allowedProviders(for: "codex-reviewers"), [.codex])
    }

    func testRealCatalogRejectsWrongProviderForSeat() throws {
        let catalog = try realCatalog()
        XCTAssertNotNil(catalog.validationProblem(ModelChoice(provider: .codex, model: "x"), for: "developer"))
        XCTAssertNotNil(catalog.validationProblem(ModelChoice(provider: .claude, model: "opus"), for: "codex-reviewers"))
        XCTAssertNotNil(catalog.validationProblem(ModelChoice(provider: .claude, model: nil), for: "scrum-master"))
        XCTAssertNotNil(catalog.validationProblem(ModelChoice(provider: .claude, model: "opus", effort: "ultra"), for: "scrum-master"))
        XCTAssertNil(catalog.validationProblem(ModelChoice(provider: .claude, model: "my/custom-id"), for: "scrum-master"))
        XCTAssertNil(catalog.validationProblem(ModelChoice(provider: .codex, model: nil), for: "codex-reviewers"))
    }

    /// The exact argument list the app emits for an untouched launch sheet
    /// (catalog defaults, Normal mode) against the real catalog.
    func testRealCatalogDefaultLaunchFlags() throws {
        let catalog = try realCatalog()
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(mode: .normal, teamModels: catalog.defaults(), flagStyle: .agentModel),
            seatOrder: catalog.seatOrder)
        let expected: [String] = [
            "--agent-model scrum-master=claude:opus@high",
            "--agent-model product-owner=claude:opus@xhigh",
            "--agent-model requirements-analyst=claude:opus@high",
            "--agent-model developer=claude:sonnet@high",
            "--agent-model codex-reviewers=codex:default",
            "--agent-model pbi-designer=claude:opus@high",
            "--agent-model pbi-implementer=claude:opus@high",
            "--agent-model pbi-ut-author=claude:opus@high",
            "--agent-model integrity-reviewers=claude:opus@xhigh",
        ]
        XCTAssertEqual(args.joined(separator: " "), expected.joined(separator: " "))
    }

    // MARK: Lenient decode

    func testLenientDecodeToleratesMissingAndUnknownFields() throws {
        let json = """
        {"future_key": 1,
         "providers": {"claude": {"models": [{"id": "opus"}]}},
         "seats": {"b": {"order": 2, "default": {"provider": "claude", "model": "opus"}},
                   "a": {"order": 1, "providers": ["claude"]},
                   "z": {}}}
        """
        let catalog = try XCTUnwrap(ModelCatalog.parse(Data(json.utf8)))
        XCTAssertEqual(catalog.seatOrder, ["a", "b", "z"])   // unordered seat last
        XCTAssertEqual(catalog.models(for: .claude).first?.displayName, "opus")
        XCTAssertEqual(catalog.efforts(for: .claude), [])
        XCTAssertEqual(catalog.displayProviders(for: "b"), [])
        // A seat without a default still yields a choice.
        XCTAssertEqual(catalog.defaults()["a"], ModelChoice(provider: .claude, model: nil))
        XCTAssertEqual(catalog.source, .builtin)   // parse never claims framework origin
    }

    func testParseRejectsNonCatalogOrSeatlessDocuments() {
        XCTAssertNil(ModelCatalog.parse(Data("{not json".utf8)))
        XCTAssertNil(ModelCatalog.parse(Data("[]".utf8)))
        XCTAssertNil(ModelCatalog.parse(Data(#"{"providers": {}}"#.utf8)))
        XCTAssertNil(ModelCatalog.parse(Data(#"{"seats": {}}"#.utf8)))
    }

    // MARK: Loading

    func testLoadFromFrameworkMarksSourceFramework() {
        let catalog = ModelCatalog.load(frameworkPath: Self.repoRoot.path)
        XCTAssertEqual(catalog.source, .framework)
        XCTAssertEqual(catalog.seatOrder.count, 9)
    }

    func testLoadFallsBackToBuiltinWhenAbsent() {
        let missing = NSTemporaryDirectory() + "maul-catalog-absent-\(UUID().uuidString)"
        let catalog = ModelCatalog.load(frameworkPath: missing)
        XCTAssertEqual(catalog.source, .builtin)
        XCTAssertEqual(catalog.seatOrder, ModelCatalog.builtin.seatOrder)
    }

    // MARK: Builtin

    func testBuiltinIsSelfConsistent() {
        let b = ModelCatalog.builtin
        XCTAssertEqual(b.source, .builtin)
        XCTAssertEqual(b.seatOrder, ["scrum-master", "product-owner"])
        XCTAssertEqual(b.models(for: .claude).map(\.id), ["opus", "fable", "sonnet", "haiku"])
        XCTAssertEqual(b.efforts(for: .claude), [])
        for (id, _) in b.seatsOrdered {
            XCTAssertEqual(b.allowedProviders(for: id), [.claude])
            XCTAssertEqual(b.displayProviders(for: id), [.claude])
            let choice = b.defaultChoice(for: id)
            XCTAssertNil(b.validationProblem(choice, for: id), "builtin default for \(id) must validate")
            XCTAssertTrue(b.models(for: .claude).contains { $0.id == choice.model },
                          "builtin default for \(id) must be in the builtin menu")
        }
        XCTAssertTrue(b.invalidSeats(in: b.defaults()).isEmpty)
    }
}
