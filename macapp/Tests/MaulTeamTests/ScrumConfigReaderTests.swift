//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the read-only `.scrum/config.json.agents` decode: the block maps to a
/// TeamModelConfig, a malformed seat is skipped rather than failing the file,
/// and "no block" is distinguishable from "empty block".
final class ScrumConfigReaderTests: XCTestCase {
    private func parse(_ json: String) -> TeamModelConfig? {
        ScrumConfigReader.parse(Data(json.utf8))
    }

    func testAgentsBlockDecodes() {
        let config = parse("""
        {"po_mode": "human", "autonomous": {"max_sprints": 3},
         "agents": {
           "scrum-master": {"provider": "claude", "model": "opus", "effort": "high"},
           "codex-reviewers": {"provider": "codex", "model": null}
         }}
        """)
        XCTAssertEqual(config?["scrum-master"], ModelChoice(provider: .claude, model: "opus", effort: "high"))
        XCTAssertEqual(config?["codex-reviewers"], ModelChoice(provider: .codex, model: nil))
        XCTAssertEqual(config?.choices.count, 2)
    }

    func testMalformedEntriesAreSkipped() {
        let config = parse("""
        {"agents": {
           "scrum-master": {"provider": "claude", "model": "opus"},
           "developer": "sonnet",
           "product-owner": {"model": "opus"},
           "pbi-designer": 42,
           "codex-reviewers": {"provider": "codex", "model": ["x"]}
         }}
        """)
        XCTAssertEqual(config?.choices.keys.sorted(), ["scrum-master"])
    }

    func testNoAgentsBlockIsNil() {
        XCTAssertNil(parse(#"{"po_mode": "agent"}"#))
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse("[]"))
    }

    func testEmptyAgentsBlockIsEmptyConfig() {
        let config = parse(#"{"agents": {}}"#)
        XCTAssertNotNil(config)
        XCTAssertTrue(config?.isEmpty ?? false)
    }

    func testUnknownProviderAndSeatAreCarriedThrough() {
        let config = parse(#"{"agents": {"future-seat": {"provider": "gemini", "model": "g"}}}"#)
        XCTAssertEqual(config?["future-seat"], ModelChoice(provider: ProviderID("gemini"), model: "g"))
    }

    func testReadsFromProjectScrumDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maul-config-\(UUID().uuidString)")
        let scrum = root.appendingPathComponent(".scrum")
        try FileManager.default.createDirectory(at: scrum, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"agents": {"developer": {"provider": "claude", "model": "sonnet"}}}"#.utf8)
            .write(to: scrum.appendingPathComponent("config.json"))

        XCTAssertEqual(ScrumConfigReader.read(projectPath: root.path)?["developer"]?.model, "sonnet")
    }

    func testAbsentFileIsNil() {
        XCTAssertNil(ScrumConfigReader.read(projectPath: NSTemporaryDirectory() + "absent-\(UUID().uuidString)"))
    }
}
