//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI
import Sparkle

/// In-app auto-update via Sparkle 2.
///
/// This REVERSES the earlier deliberate "not a self-updater" decision: updates
/// are now delivered inside the app from an EdDSA-signed appcast on the
/// `appcast` branch (SUFeedURL / SUPublicEDKey are injected into Info.plist by
/// make-app.sh). The dmg funnel still exists for first install; Sparkle takes
/// over for every subsequent version.
///
/// Wiring follows the official Sparkle 2 SwiftUI pattern:
///   - the App struct owns a single `SPUStandardUpdaterController` (plain `let`),
///   - `CheckForUpdatesViewModel` mirrors the updater's `canCheckForUpdates` so
///     the menu item disables itself while a check can't run,
///   - `CheckForUpdatesView` is the "Check for Updates…" menu button.
///
/// Automatic-check consent is intentionally left to Sparkle: SUEnableAutomaticChecks
/// is UNSET in Info.plist, so Sparkle prompts the user for permission on the
/// second launch (the desired UX) rather than silently phoning home.

/// Observes `SPUUpdater.canCheckForUpdates` so SwiftUI can disable the menu item
/// while an update check is already in flight (or the updater isn't ready).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu button. Kept identical in title to the old
/// UpdateChecker entry so the menu is unchanged from the user's perspective.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        // Retain a view model so the button's disabled state tracks the updater.
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
