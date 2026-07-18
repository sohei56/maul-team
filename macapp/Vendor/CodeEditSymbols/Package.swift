// swift-tools-version: 5.9

// Vendored copy of CodeEditApp/CodeEditSymbols v0.2.3 (ae69712).
// Upstream's manifest omits the `resources:` declaration for
// Symbols.xcassets, so `Bundle.module` is never synthesized and CLI
// `swift build` fails (Xcode auto-detects the asset catalog; SwiftPM's
// command-line build does not). This local package overrides the remote
// transitive dependency by identity and declares the resource explicitly.
// Drop it once upstream ships a manifest with the resources declaration.

import PackageDescription

let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            resources: [
                .process("Symbols.xcassets")
            ]
        ),
    ]
)
