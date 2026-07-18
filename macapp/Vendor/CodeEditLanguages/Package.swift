// swift-tools-version: 5.7

// Vendored copy of CodeEditApp/CodeEditLanguages v0.1.20 (the exact version
// CodeEditSourceEditor pins). Two local patches, both required because this
// app is assembled by `swift build` + make-app.sh rather than Xcode:
//
//   1. CodeLanguage.swift — layout-aware query resolution. Upstream hardcodes
//      an extra "Resources/" path segment that only exists in Xcode-built
//      resource bundles; in SPM CLI bundles it doubles to Resources/Resources
//      and every highlight query silently fails to load (gray text).
//   2. CodeLanguage.swift — the generated Bundle.module accessor only checks
//      the .app root and the dev machine's absolute .build path, so a
//      distributed .app can never find the bundle. We resolve it from
//      Contents/Resources (where make-app.sh copies it) first.
//
// The tree-sitter grammar container ships upstream as a 33 MB zip committed
// to their repo; we reference the identical blob remotely (same tag) instead
// of committing it here. Drop this vendored package once upstream handles
// non-Xcode bundle layouts.

import PackageDescription

let package = Package(
    name: "CodeEditLanguages",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditLanguages",
            targets: ["CodeEditLanguages"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            from: "0.9.0"
        ),
    ],
    targets: [
        .target(
            name: "CodeEditLanguages",
            dependencies: ["CodeLanguagesContainer", "SwiftTreeSitter"],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),

        .binaryTarget(
            name: "CodeLanguagesContainer",
            url: "https://raw.githubusercontent.com/CodeEditApp/CodeEditLanguages/0.1.20/CodeLanguagesContainer.xcframework.zip",
            checksum: "c6ee69d9d373a9c3cf93d239e05369d9b941275d31cd7956d0dc83b5a5c3e152"
        ),
    ]
)
