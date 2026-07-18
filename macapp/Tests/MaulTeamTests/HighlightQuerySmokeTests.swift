//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
import CodeEditLanguages

/// The editor's tree-sitter highlighting fails SILENTLY (TreeSitterModel's
/// query loaders are all `try?`) — a missing/corrupt query bundle renders
/// plain gray text with no error anywhere. These tests make that failure
/// loud at CI time by exercising the same loading chain the app uses.
final class HighlightQuerySmokeTests: XCTestCase {
    func testQueryURLResolvesAndExists() throws {
        let url = try XCTUnwrap(CodeLanguage.json.queryURL, "queryURL nil — Bundle.module resolution failed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "highlights.scm missing at \(url.path)"
        )
    }

    func testHighlightQueriesCompile() {
        for lang: TreeSitterLanguage in [.json, .swift, .markdown, .bash, .yaml] {
            XCTAssertNotNil(
                TreeSitterModel.shared.query(for: lang),
                "highlight query failed to load/compile for \(lang)"
            )
        }
    }
}
