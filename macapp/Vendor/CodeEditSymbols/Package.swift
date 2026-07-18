// swift-tools-version: 5.9

// Vendored copy of CodeEditApp/CodeEditSymbols v0.2.3 (ae69712).
// Two patches relative to upstream:
//  1. Manifest (this file): upstream omits the `resources:` declaration for
//     Symbols.xcassets, so `Bundle.module` is never synthesized and CLI
//     `swift build` fails (Xcode auto-detects the asset catalog; SwiftPM's
//     command-line build does not). This local package overrides the remote
//     transitive dependency by identity and declares the resource explicitly.
//  2. Runtime (Sources/CodeEditSymbols/CodeEditSymbols.swift): upstream reads
//     `Bundle.module`, whose SwiftPM-generated accessor cannot find the
//     resource bundle inside a distributed .app (it only searches the
//     build-machine .build path and the main-bundle root). The vendored
//     `symbolsBundle` property first probes
//     Contents/Resources/CodeEditSymbols_CodeEditSymbols.bundle — where
//     make-app.sh copies it — before falling back to `Bundle.module`.
// Drop this package once upstream ships both fixes.

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
