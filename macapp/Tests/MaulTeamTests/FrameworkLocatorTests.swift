//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pure-function coverage for the content-keyed extraction naming. The
/// extraction/cleanup filesystem behavior is verified on-device per
/// macapp/CLAUDE.md (launch the .app); these pin the naming contract that
/// keeps an extracted framework in lockstep with the bundled content.
final class FrameworkLocatorTests: XCTestCase {
    // MARK: parseRevisionMarker

    func testParsesFullShaToTwelveChars() {
        XCTAssertEqual(
            FrameworkLocator.parseRevisionMarker("0123456789abcdef0123456789abcdef01234567\n"),
            "0123456789ab")
    }

    func testTrimsWhitespaceAndUsesFirstLineOnly() {
        XCTAssertEqual(
            FrameworkLocator.parseRevisionMarker("  abc123  \nsecond-line\n"),
            "abc123")
    }

    func testShortRevisionPassesThrough() {
        XCTAssertEqual(FrameworkLocator.parseRevisionMarker("abc123"), "abc123")
    }

    func testEmptyOrWhitespaceMarkerIsNil() {
        XCTAssertNil(FrameworkLocator.parseRevisionMarker(""))
        XCTAssertNil(FrameworkLocator.parseRevisionMarker("\n"))
        XCTAssertNil(FrameworkLocator.parseRevisionMarker("   \n\n"))
    }

    // MARK: extractionDirName

    func testContentKeyedNameCombinesVersionAndRev() {
        XCTAssertEqual(
            FrameworkLocator.extractionDirName(version: "2.0.3", rev: "0123456789ab"),
            "framework-2.0.3-0123456789ab")
    }

    func testPreMarkerBundleFallsBackToLegacyName() {
        XCTAssertEqual(
            FrameworkLocator.extractionDirName(version: "2.0.3", rev: nil),
            "framework-2.0.3")
        XCTAssertEqual(
            FrameworkLocator.extractionDirName(version: "2.0.3", rev: ""),
            "framework-2.0.3")
    }

    func testDistinctRevsYieldDistinctDirs() {
        let a = FrameworkLocator.extractionDirName(version: "2.0.3", rev: "aaaaaaaaaaaa")
        let b = FrameworkLocator.extractionDirName(version: "2.0.3", rev: "bbbbbbbbbbbb")
        XCTAssertNotEqual(a, b)
    }
}
