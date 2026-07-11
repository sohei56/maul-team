//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// A colored status pill for a PBI's 13-value status.
struct StatusBadge: View {
    let status: String
    var body: some View {
        let color = PBIStatus.color(status)
        Text("\(PBIStatus.icon(status)) \(PBIStatus.label(status))")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }
}

/// A pass/fail/skipped pill for integration test categories and overall status.
struct ResultBadge: View {
    let status: String
    var body: some View {
        Text(status.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Self.color(status).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(status))
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "passed": return .green
        case "passed_with_skips": return .mint
        case "failed": return .red
        case "skipped": return .secondary
        case "running": return .blue
        default: return .secondary
        }
    }
}

/// A titled card container with a subtle background.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
