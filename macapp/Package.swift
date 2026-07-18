// swift-tools-version: 5.9

//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import PackageDescription

// MaulTeam — native macOS shell for the maul-team framework.
//
// MVP (A): a launcher + 3-pane workspace that embeds the EXISTING tmux-free
// Scrum Master session and Textual dashboard in SwiftTerm panes. No framework
// logic is reimplemented here — the app shells out to scrum-start.sh
// (SCRUM_NO_TMUX=1) and dashboard/app.py so the proven backend stays the SSOT.
let package = Package(
    name: "MaulTeam",
    platforms: [
        // macOS 14: required by SettingsLink and the modern SwiftUI APIs used.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // Tree-sitter based code editor (CodeEdit): semantic highlighting,
        // line-number gutter, find/replace. Pinned exact — upstream README
        // declares the package "not ready for production use", so upgrades
        // must be deliberate, spike-tested bumps.
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", exact: "0.15.2"),
        // Local overrides of CodeEditSourceEditor's transitive dependencies —
        // both are patched for CLI-built (non-Xcode) apps; see each
        // Vendor/*/Package.swift header for the specific defect.
        .package(path: "Vendor/CodeEditLanguages"),
        .package(path: "Vendor/CodeEditSymbols")
    ],
    targets: [
        .executableTarget(
            name: "MaulTeam",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages")
            ],
            path: "Sources/MaulTeam"
        ),
        .testTarget(
            name: "MaulTeamTests",
            dependencies: ["MaulTeam"],
            path: "Tests/MaulTeamTests"
        )
    ]
)
