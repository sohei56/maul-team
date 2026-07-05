//
// ScrumTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Persists the recent-projects list as JSON under Application Support.
enum RecentProjectsStore {
    private static let maxRecents = 20

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ScrumTeam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }

    static func load() -> [Project] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder.iso.decode([Project].self, from: data)
        else { return [] }
        // Drop entries whose directory has since been deleted/moved.
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    static func save(_ projects: [Project]) {
        guard let data = try? JSONEncoder.iso.encode(Array(projects.prefix(maxRecents))) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Insert or move-to-front while deduping by path.
    static func upsert(_ project: Project, into list: [Project]) -> [Project] {
        var out = list.filter { $0.id != project.id }
        out.insert(project, at: 0)
        return Array(out.prefix(maxRecents))
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e
    }()
}
