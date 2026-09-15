//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import Foundation

/// Everything the launch sheet decides for a fresh session: the mode plus the
/// per-seat model table, and how the table is handed to `scrum-start.sh`.
/// Ignored when re-attaching to a running session.
struct LaunchOptions: Equatable {
    /// How team models reach the launcher.
    enum FlagStyle: Equatable {
        /// `--agent-model <seat>=<provider>:<model>[@<effort>]` for every seat
        /// in catalog order — the framework that ships a model catalog.
        case agentModel
        /// `--sm-model <model>` (+ `--po-model <model>` in Autonomous mode) —
        /// a framework checkout that predates the catalog.
        case legacy
    }

    var mode: LaunchMode = .normal
    var teamModels: TeamModelConfig = TeamModelConfig()
    var flagStyle: FlagStyle = .agentModel

    init(mode: LaunchMode = .normal, teamModels: TeamModelConfig = TeamModelConfig(),
         flagStyle: FlagStyle = .agentModel) {
        self.mode = mode
        self.teamModels = teamModels
        self.flagStyle = flagStyle
    }

    /// The flag style a catalog implies: a builtin catalog means the framework
    /// never told us it understands `--agent-model`.
    static func flagStyle(for catalog: ModelCatalog) -> FlagStyle {
        catalog.source == .builtin ? .legacy : .agentModel
    }
}
