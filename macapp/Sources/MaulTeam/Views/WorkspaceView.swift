//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import SwiftUI

/// The editor-like workspace:
///   left   = file tree (Explorer); files open in detached editor windows
///   center = Scrum Master terminal (top) + native Work Log (bottom)
///   right  = native project/PBI/integration dashboard
///
/// The Scrum Master terminal comes from a long-lived ProjectSession in the
/// SessionStore, so leaving to the picker — or switching to another tab —
/// leaves it running in the background. Only closing a tab stops a session.
/// The dashboard and work log are native, polling the project's `.scrum/` state.
struct WorkspaceView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var attention: AttentionMonitor
    let project: Project

    @State private var stopCandidate: Project?
    @State private var showInfo = false
    @StateObject private var editor = EditorModel()
    @StateObject private var dashboard: DashboardModel

    init(project: Project) {
        self.project = project
        _dashboard = StateObject(wrappedValue: DashboardModel(projectPath: project.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let session = sessions.existingSession(for: project.id) {
                panes(session: session)
            } else {
                ProgressView("Starting session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            _ = sessions.session(for: project, frameworkPath: state.resolvedFrameworkPath, mode: state.pendingLaunchMode)
        }
        .task {
            // Poll .scrum/ state for the native dashboard + work log while shown.
            while !Task.isCancelled {
                dashboard.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Stop \(stopCandidate?.name ?? "Session")?",
            isPresented: stopDialogShown, titleVisibility: .visible, presenting: stopCandidate
        ) { target in
            Button("Stop Session", role: .destructive) { stopSession(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Ends the Scrum Master session for \(target.name) and any unsaved conversation state is lost. The project stays in the Projects list.")
        }
    }

    private var stopDialogShown: Binding<Bool> {
        Binding(get: { stopCandidate != nil }, set: { if !$0 { stopCandidate = nil } })
    }

    /// Stop a session and close its tab. Closing the active tab moves to the
    /// neighbouring one (or back to the picker when it was the last).
    private func stopSession(_ target: Project) {
        let index = sessions.openProjects.firstIndex { $0.id == target.id } ?? 0
        sessions.stop(target.id)
        guard target.id == project.id else { return }
        let remaining = sessions.openProjects
        if remaining.isEmpty {
            state.closeProject()
        } else {
            state.open(remaining[min(index, remaining.count - 1)])
        }
    }

    private func panes(session: ProjectSession) -> some View {
        // NSSplitView-backed; divider positions persist across launches (drag to
        // set your defaults). Env objects must be injected per hosted pane — they
        // do not cross the NSHostingView boundary inside SplitContainer.
        let left = AnyView(
            FileTreeView(rootPath: project.path)
                .environmentObject(editor).environmentObject(state)
                .textSelection(.enabled)
        )
        let center = AnyView(
            SplitContainer(
                isVertical: false, storageKey: "ws.center",
                minSizes: [200, 140], initialFractions: [0.655],
                panes: [
                    AnyView(paneContainer(title: "Scrum Master", systemImage: "bubble.left.and.bubble.right.fill") {
                        TerminalPaneView(terminal: session.smTerminal)
                    }),
                    AnyView(paneContainer(title: "Work Log", systemImage: "list.bullet.rectangle") {
                        WorkLogView(model: dashboard)
                    }.textSelection(.enabled)),
                ])
        )
        let right = AnyView(
            paneContainer(title: "Dashboard", systemImage: "chart.bar.doc.horizontal") {
                DashboardView(model: dashboard)
            }
            .environmentObject(state)
            .textSelection(.enabled)
        )
        return SplitContainer(
            isVertical: true, storageKey: "ws.h",
            minSizes: [180, 360, 300], initialFractions: [0.184, 0.729],
            panes: [left, center, right])
    }

    /// Open projects in insertion order. The active project is appended when the
    /// store has not registered it yet — the first frame renders before
    /// `onAppear` creates its session.
    private var tabProjects: [Project] {
        var tabs = sessions.openProjects
        if !tabs.contains(where: { $0.id == project.id }) { tabs.append(project) }
        return tabs
    }

    private var toolbar: some View {
        // Folder-style tab strip: the bar's bottom hairline (replacing the old
        // Divider below the toolbar) runs the full width, chips sit on it, and
        // the active chip's opaque fill covers its segment so the tab reads as
        // connected to the content area below.
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            HStack(alignment: .bottom, spacing: 10) {
                Group {
                    Button { state.closeProject() } label: {
                        Label("Projects", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to Projects — sessions keep running in the background")

                    Divider().frame(height: 16)
                }
                .padding(.bottom, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(tabProjects) { tab in
                            ProjectTab(
                                project: tab,
                                isActive: tab.id == project.id,
                                isRunning: sessions.isRunning(tab.id),
                                // Shown on the active tab too — the prompt is
                                // still unanswered even while it is in view.
                                hasAttention: attention.pending[tab.id] != nil,
                                select: { if tab.id != project.id { state.open(tab) } },
                                close: { stopCandidate = tab })
                        }
                    }
                }
                // Without this the scroll view is flexible vertically and the
                // toolbar row grows to eat the panes' height.
                .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Group {
                    if state.advancedUnlocked {
                        Label("Advanced", systemImage: "lock.open.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("About & feedback")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPopover() }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private func paneContainer<Content: View>(
        title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(.secondary)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            Divider()
            content()
        }
    }
}

/// One chip in the workspace tab strip, drawn as a classic folder tab: rounded
/// top corners, sides running down onto the bar's bottom hairline, no bottom
/// edge. The active chip is taller and its opaque fill hides the hairline
/// beneath it. A subview so hover state is per-chip.
private struct ProjectTab: View {
    let project: Project
    let isActive: Bool
    let isRunning: Bool
    let hasAttention: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private var fillShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 7)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.caption)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(project.name)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            // A waiting prompt takes the run lamp's slot — it is the more
            // urgent fact about the session, and the lamp returns once the
            // prompt clears.
            if hasAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("Waiting for your input")
            } else {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                    .help(isRunning ? "Running" : "Session stopped")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop this session and close the tab")
        }
        .padding(.horizontal, 10)
        .padding(.top, isActive ? 8 : 5)   // the active tab stands taller
        .padding(.bottom, 6)
        .background(
            ZStack {
                if isActive {
                    // Opaque base first: the accent tint alone is translucent
                    // and would let the hairline show through.
                    fillShape.fill(Color(nsColor: .windowBackgroundColor))
                    fillShape.fill(Color.accentColor.opacity(0.12))
                } else if isHovering {
                    fillShape.fill(Color.primary.opacity(0.06))
                }
            }
        )
        .overlay(
            FolderTabBorder(radius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                        lineWidth: 1)
        )
        .contentShape(fillShape)
        .textSelection(.disabled)   // this chip navigates; don't select the name text
        .onTapGesture { if !isActive { select() } }
        .onHover { isHovering = $0 }
        .help(project.path)
    }
}

/// The stroke outline of a folder tab — left side up, rounded top, right side
/// down — deliberately leaving the bottom edge open. Inset by half the line
/// width on the sides/top so a 1pt stroke stays inside the chip bounds.
private struct FolderTabBorder: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX + 0.5, maxX = rect.maxX - 0.5, minY = rect.minY + 0.5
        var p = Path()
        p.move(to: CGPoint(x: minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: minX, y: minY + radius))
        p.addQuadCurve(to: CGPoint(x: minX + radius, y: minY), control: CGPoint(x: minX, y: minY))
        p.addLine(to: CGPoint(x: maxX - radius, y: minY))
        p.addQuadCurve(to: CGPoint(x: maxX, y: minY + radius), control: CGPoint(x: maxX, y: minY))
        p.addLine(to: CGPoint(x: maxX, y: rect.maxY))
        return p
    }
}
