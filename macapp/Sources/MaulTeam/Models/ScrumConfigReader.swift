//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// `.scrum/config.json` as far as the app reads it: only the `agents` block
/// (seat → provider/model/effort). Every other key is ignored, and a
/// malformed seat entry is skipped rather than failing the whole file.
struct ScrumConfigFile: Decodable {
    /// Decodes an entry when it can and records nil otherwise, so one bad
    /// seat does not discard the rest of the block.
    struct LenientChoice: Decodable {
        let choice: ModelChoice?

        private struct Raw: Decodable {
            var provider: String?
            var model: String?
            var effort: String?
        }

        init(from decoder: Decoder) throws {
            guard let raw = try? Raw(from: decoder),
                  let provider = raw.provider, !provider.isEmpty
            else { choice = nil; return }
            choice = ModelChoice(provider: ProviderID(provider), model: raw.model, effort: raw.effort)
        }
    }

    var agents: [String: LenientChoice]?

    /// nil when the file has no `agents` block; an empty config when the block
    /// exists but holds nothing usable.
    var teamModels: TeamModelConfig? {
        guard let agents else { return nil }
        return TeamModelConfig(choices: agents.compactMapValues(\.choice))
    }
}

/// Read-only access to `.scrum/config.json.agents`. The app never writes the
/// file — the framework's `agent-models.sh` wrapper is its sole writer.
enum ScrumConfigReader {
    nonisolated static func read(projectPath: String) -> TeamModelConfig? {
        let url = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".scrum")
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// nil when the data is not a JSON object or has no `agents` block.
    nonisolated static func parse(_ data: Data) -> TeamModelConfig? {
        guard let file = try? JSONDecoder().decode(ScrumConfigFile.self, from: data) else { return nil }
        return file.teamModels
    }
}
