//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the `.scrum/attention.json` contract: only an explicit `pending: true`
/// counts, and every other shape (cleared, malformed, absent) reads as "nothing
/// waiting". Badge/banner delivery is verified on-device per macapp/CLAUDE.md —
/// these cover the decode, which is what decides whether anything is shown.
///
/// Deliberately reaches only the nonisolated statics: touching
/// UNUserNotificationCenter from an unbundled test process raises.
final class AttentionMonitorTests: XCTestCase {
    private func parse(_ json: String) -> AttentionState? {
        AttentionMonitor.parse(Data(json.utf8))
    }

    func testPendingPromptDecodesAllFields() {
        let state = parse("""
        {"pending": true, "type": "permission_prompt", "message": "Approve the merge?",
         "agent": "scrum-master", "updated_at": "2026-08-01T05:00:00Z"}
        """)
        XCTAssertEqual(state?.type, "permission_prompt")
        XCTAssertEqual(state?.message, "Approve the merge?")
        XCTAssertEqual(state?.updatedAt, "2026-08-01T05:00:00Z")
    }

    func testClearedPromptIsNil() {
        XCTAssertNil(parse(#"{"pending": false, "message": "stale"}"#))
    }

    func testMissingPendingFlagIsNil() {
        XCTAssertNil(parse(#"{"type": "idle_prompt", "message": "hi"}"#))
    }

    func testMalformedJSONIsNil() {
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse(""))
    }

    /// Optional fields really are optional — `agent` and `type` are documented
    /// as omissible, and a bare flag must still raise the badge.
    func testPendingWithoutOptionalFieldsStillCounts() {
        let state = parse(#"{"pending": true}"#)
        XCTAssertNotNil(state)
        XCTAssertNil(state?.message)
        XCTAssertNil(state?.updatedAt)
    }

    /// An unknown `type` is carried through rather than rejected, so a future
    /// prompt kind still notifies.
    func testUnknownTypeIsCarriedThrough() {
        XCTAssertEqual(parse(#"{"pending": true, "type": "future_prompt"}"#)?.type, "future_prompt")
    }

    func testAbsentFileIsNil() {
        let missing = NSTemporaryDirectory() + "maul-attention-absent-\(UUID().uuidString)"
        XCTAssertNil(AttentionMonitor.read(projectPath: missing))
    }
}
