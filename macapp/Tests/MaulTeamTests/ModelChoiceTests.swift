//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins `ModelChoice.isValidModelToken` to the framework's bash
/// `is_safe_model_token` (`^[A-Za-z0-9][A-Za-z0-9._/-]*$`) with a table both
/// sides agree on, and the `--agent-model` value spelling.
final class ModelChoiceTests: XCTestCase {
    func testAcceptedTokens() {
        for token in ["opus", "gpt-5.6-luna", "claude-opus-4/latest", "a", "0x", "A_b.c/d-e"] {
            XCTAssertTrue(ModelChoice.isValidModelToken(token), "should accept \(token.debugDescription)")
        }
    }

    func testRejectedTokens() {
        for token in ["", "-x", ".x", "/x", "_x", "a b", "a'b", "a\nb", "日本", "a;b", "a$b", "a\\b", "opus "] {
            XCTAssertFalse(ModelChoice.isValidModelToken(token), "should reject \(token.debugDescription)")
        }
    }

    func testFlagValueSpelling() {
        XCTAssertEqual(ModelChoice(provider: .claude, model: "opus", effort: "high").flagValue, "claude:opus@high")
        XCTAssertEqual(ModelChoice(provider: .claude, model: "opus").flagValue, "claude:opus")
        XCTAssertEqual(ModelChoice(provider: .codex, model: nil).flagValue, "codex:default")
        XCTAssertEqual(ModelChoice(provider: .codex, model: "gpt-5.6-luna").flagValue, "codex:gpt-5.6-luna")
        XCTAssertEqual(ModelChoice(provider: .claude, model: "opus", effort: "").flagValue, "claude:opus")
    }

    func testCodableRoundTripKeepsNilModel() throws {
        let original = TeamModelConfig(choices: [
            "codex-reviewers": ModelChoice(provider: .codex, model: nil),
            "scrum-master": ModelChoice(provider: .claude, model: "opus", effort: "high"),
        ])
        let data = try JSONEncoder().encode(original)
        // Bare dictionary shape, provider as a plain string.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sm = try XCTUnwrap(object["scrum-master"] as? [String: Any])
        XCTAssertEqual(sm["provider"] as? String, "claude")
        XCTAssertEqual(try JSONDecoder().decode(TeamModelConfig.self, from: data), original)
    }

    func testMergingOverPrefersSelf() {
        let base = TeamModelConfig(choices: [
            "a": ModelChoice(provider: .claude, model: "opus"),
            "b": ModelChoice(provider: .claude, model: "sonnet"),
        ])
        let over = TeamModelConfig(choices: ["b": ModelChoice(provider: .claude, model: "haiku")])
        let merged = over.merging(over: base)
        XCTAssertEqual(merged["a"]?.model, "opus")
        XCTAssertEqual(merged["b"]?.model, "haiku")
    }
}
