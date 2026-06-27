// swift-tools-version: 5.9
import PackageDescription

// ScrumTeam — native macOS shell for the claude-scrum-team framework.
//
// MVP (A): a launcher + 3-pane workspace that embeds the EXISTING tmux-free
// Scrum Master session and Textual dashboard in SwiftTerm panes. No framework
// logic is reimplemented here — the app shells out to scrum-start.sh
// (SCRUM_NO_TMUX=1) and dashboard/app.py so the proven backend stays the SSOT.
let package = Package(
    name: "ScrumTeam",
    platforms: [
        // macOS 14: required by SettingsLink and the modern SwiftUI APIs used.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ScrumTeam",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ScrumTeam"
        )
    ]
)
