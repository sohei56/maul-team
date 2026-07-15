//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// A project the user has opened — a directory on disk that the Scrum team
/// operates inside. Identity is the absolute path so recents dedup naturally.
struct Project: Identifiable, Codable, Hashable {
    var path: String          // absolute directory path
    var lastOpened: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// True once the framework has been deployed into the project (setup-user.sh
    /// drops `.scrum/` + `.claude/`). Used by the picker to label "new" projects.
    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".scrum"))
    }

    /// True when a product brief already exists at `docs/product/brief.md`.
    /// Autonomous mode needs a brief to anchor scope — when absent, the terminal
    /// co-authors one (the create-brief skill) before the run starts, so the
    /// launch picker surfaces an extra heads-up.
    var hasBrief: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("docs/product/brief.md"))
    }
}
