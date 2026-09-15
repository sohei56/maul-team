//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the `recents.json` shape through the store's own encoder/decoder: the
/// optional `teamModels` cache round-trips, and a file written before the
/// field existed still loads.
final class RecentProjectsStoreTests: XCTestCase {
    func testRoundTripWithTeamModels() throws {
        let table = TeamModelConfig(choices: [
            "scrum-master": ModelChoice(provider: .claude, model: "opus", effort: "high"),
            "codex-reviewers": ModelChoice(provider: .codex, model: nil),
        ])
        let projects = [
            Project(path: "/tmp/a", lastOpened: Date(timeIntervalSince1970: 1_700_000_000), teamModels: table),
            Project(path: "/tmp/b", lastOpened: Date(timeIntervalSince1970: 1_600_000_000)),
        ]
        let data = try XCTUnwrap(RecentProjectsStore.encode(projects))
        let back = try XCTUnwrap(RecentProjectsStore.decode(data))
        XCTAssertEqual(back, projects)
        XCTAssertEqual(back[0].teamModels, table)
        XCTAssertNil(back[1].teamModels)
    }

    func testLegacyFileWithoutTeamModelsDecodes() throws {
        let legacy = """
        [{"path": "/tmp/old", "lastOpened": "2026-07-01T00:00:00Z"}]
        """
        let back = try XCTUnwrap(RecentProjectsStore.decode(Data(legacy.utf8)))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].path, "/tmp/old")
        XCTAssertNil(back[0].teamModels)
    }

    func testTeamModelsIsStoredAsBareSeatDictionary() throws {
        let project = Project(path: "/tmp/a", lastOpened: Date(),
                              teamModels: TeamModelConfig(choices: ["developer": ModelChoice(provider: .claude, model: "sonnet")]))
        let data = try XCTUnwrap(RecentProjectsStore.encode([project]))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let tm = try XCTUnwrap(array[0]["teamModels"] as? [String: Any])
        let dev = try XCTUnwrap(tm["developer"] as? [String: Any])
        XCTAssertEqual(dev["provider"] as? String, "claude")
        XCTAssertEqual(dev["model"] as? String, "sonnet")
    }

    func testUpsertMovesToFrontAndKeepsCache() {
        let table = TeamModelConfig(choices: ["scrum-master": ModelChoice(provider: .claude, model: "fable")])
        let a = Project(path: "/a", lastOpened: Date())
        let b = Project(path: "/b", lastOpened: Date())
        let updatedA = Project(path: "/a", lastOpened: Date(), teamModels: table)
        let list = RecentProjectsStore.upsert(updatedA, into: [b, a])
        XCTAssertEqual(list.map(\.path), ["/a", "/b"])
        XCTAssertEqual(list[0].teamModels, table)
    }
}
