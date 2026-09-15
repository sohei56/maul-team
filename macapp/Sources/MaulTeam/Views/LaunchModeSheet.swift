//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// Modal shown before a fresh session starts: choose Normal vs Autonomous
/// (with an explanation of each) and the per-seat team models. Re-attaching to
/// a running session skips this.
struct LaunchModeSheet: View {
    let project: Project
    let catalog: ModelCatalog
    /// Seats whose saved choice the prefill had to reset (shown as a note).
    let coercedSeats: Set<String>
    @Binding var selection: LaunchMode
    @Binding var teamModels: TeamModelConfig
    let onStart: () -> Void
    let onCancel: () -> Void

    private var canStart: Bool { catalog.invalidSeats(in: teamModels).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How should the team run?").font(.title2.bold())
                        Text(project.name).font(.callout).foregroundStyle(.secondary)
                    }

                    ForEach(LaunchMode.allCases) { mode in
                        modeCard(mode)
                    }

                    if selection == .autonomous {
                        autonomousGuidance
                    }

                    Divider()

                    TeamModelsSection(
                        catalog: catalog, mode: selection,
                        coercedSeats: coercedSeats, config: $teamModels)
                }
                .padding(24)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 720)

            Divider()
            HStack {
                if !canStart {
                    Label("Fix the highlighted model id to start", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(selection == .autonomous ? "Continue in Terminal" : "Start", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620)
    }

    /// Heads-up shown once Autonomous is selected: the run limits (and, for a
    /// new project, the brief brainstorm) are still answered in the terminal
    /// pane. Team models are NOT — they are chosen here and passed to the
    /// launcher as flags, so the terminal never asks for them.
    private var autonomousGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Setup continues in the terminal", systemImage: "terminal")
                .font(.callout.weight(.semibold))
            guidanceRow(
                "number.square",
                "First, the terminal asks you to set the run limits — how many "
                + "sprints to auto-run and max hours. Type your answers in the "
                + "terminal pane; the run won't start until you do.")
            guidanceRow(
                "cpu",
                "Team models are taken from the Team models section below and "
                + "handed to the launcher — the terminal will not ask for them.")
            if !project.hasBrief {
                guidanceRow(
                    "text.book.closed",
                    "This project has no product brief yet. The terminal then "
                    + "walks you through co-authoring one — finish that Q&A "
                    + "(the \"壁打ち\") in the terminal before the autonomous run begins.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func guidanceRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeCard(_ mode: LaunchMode) -> some View {
        let isSelected = selection == mode
        return Button { selection = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemImage).foregroundStyle(.tint)
                        Text(mode.title).font(.headline)
                        Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(mode.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
