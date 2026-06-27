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
}
