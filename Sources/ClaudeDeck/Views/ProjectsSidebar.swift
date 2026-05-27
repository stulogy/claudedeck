import SwiftUI

/// Primary nav. One row per project (i.e. unique cwd), showing attention/working
/// counts and total memory % of system RAM. Resizable: the column collapses to a
/// compact icon-rail layout when dragged below ~150pt.
struct ProjectsSidebar: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @EnvironmentObject var summarizer: Summarizer
    @Environment(\.openSettings) private var openSettings
    @State private var showNewSessionSheet = false

    /// Width threshold below which the sidebar uses the compact layout.
    static let compactBreakpoint: CGFloat = 150
    static let minWidth: CGFloat = 72
    static let defaultWidth: CGFloat = 300

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < Self.compactBreakpoint
            ZStack {
                sidebarBackground
                VStack(spacing: 0) {
                    header(compact: compact)
                    Divider().opacity(0.3)
                    newButton(compact: compact)
                        .padding(.horizontal, compact ? 8 : 14)
                        .padding(.vertical, 14)
                    Divider().opacity(0.3)
                    content(compact: compact)
                    Divider().opacity(0.3)
                    footer(compact: compact)
                }
            }
        }
        .frame(minWidth: Self.minWidth)
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(isPresented: $showNewSessionSheet)
                .environmentObject(hosted)
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckNewSession)) { _ in
            showNewSessionSheet = true
        }
    }

    // MARK: - Background

    private var sidebarBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { proxy in
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: proxy.size.width * 1.4)
                    .blur(radius: 120)
                    .offset(x: -proxy.size.width * 0.4, y: -proxy.size.height * 0.5)
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: proxy.size.width * 1.2)
                    .blur(radius: 140)
                    .offset(x: proxy.size.width * 0.3, y: proxy.size.height * 0.6)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    @ViewBuilder
    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BrandGradient.warm)
                    .frame(width: 30, height: 30)
                    .shadow(color: Color.accentColor.opacity(0.45), radius: 8, x: 0, y: 4)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ClaudeDeck")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(countLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }

    private var countLabel: String {
        let n = hosted.projects.count
        return n == 1 ? "1 project" : "\(n) projects"
    }

    // MARK: - New project button

    @ViewBuilder
    private func newButton(compact: Bool) -> some View {
        Button {
            showNewSessionSheet = true
        } label: {
            if compact {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(BrandGradient.warm)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, x: 0, y: 3)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("New session")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BrandGradient.warm)
                )
                .foregroundStyle(.white)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, x: 0, y: 4)
            }
        }
        .buttonStyle(.plain)
        .help(compact ? "New session (⌘⇧S)" : "")
    }

    // MARK: - Content list

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        let projects = hosted.projects
        if projects.isEmpty {
            emptyState(compact: compact)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(projects) { project in
                        ProjectRow(project: project, compact: compact)
                    }
                    // Drop zone past the last row so users can drag a project
                    // to the bottom. Without this there's no target there and
                    // the drag silently fails.
                    EndProjectDropZone()
                }
                .padding(.horizontal, compact ? 6 : 10)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func emptyState(compact: Bool) -> some View {
        if compact {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No projects yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Click New session above to start your first Claude Code session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(SidebarIconButtonStyle())
            .help("Settings (⌘,)")
            if !compact {
                Spacer()
                if let totalMB = totalMemory {
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(totalMB)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }

    private var totalMemory: String? {
        let total = hosted.sessions.compactMap { $0.memoryRSS }.reduce(UInt64(0), &+)
        guard total > 0 else { return nil }
        let mb = Double(total) / (1024 * 1024)
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: Project
    let compact: Bool
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var hover = false
    @State private var showInfoPopover = false
    @State private var isDropTarget = false

    private var isActive: Bool { hosted.activeProject?.cwd == project.cwd }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .padding(compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            // Horizontal insertion bar while a project is being dragged over this row.
            if isDropTarget {
                Rectangle()
                    .fill(Color.activeHighlight)
                    .frame(height: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(compact ? compactTooltip : "")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        // `.draggable` would otherwise swallow plain clicks. A simultaneous
        // tap gesture keeps "click row to activate the project" working even
        // when the row is also draggable for reordering.
        .simultaneousGesture(TapGesture().onEnded {
            hosted.activateProject(project)
        })
        .draggable("project::\(project.cwd)") {
            // Pill drag preview so it's clear the whole project block is moving.
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.activeHighlight.opacity(0.9)))
            .foregroundStyle(.white)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, raw.hasPrefix("project::") else { return false }
            let movedCwd = String(raw.dropFirst("project::".count))
            hosted.reorderProject(movedCwd: movedCwd, before: project.cwd)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .contextMenu {
            Button("Show Folder in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: project.cwd))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.cwd, forType: .string)
            }
        }
    }

    private var compactTooltip: String {
        var parts: [String] = [project.name]
        if project.attentionCount > 0 { parts.append("\(project.attentionCount) waiting") }
        if project.workingCount > 0   { parts.append("\(project.workingCount) running") }
        if project.idleCount > 0      { parts.append("\(project.idleCount) idle") }
        if let mem = project.prettyTotalMemory {
            parts.append("\(mem) · \(Int(project.memoryPercentOfRAM.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Compact (narrow column)

    private var compactBody: some View {
        VStack(spacing: 4) {
            // Initial(s) of the project name as the primary identifier.
            Text(initialBadge)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.accentColor)
                )
                .overlay(alignment: .topTrailing) {
                    if project.attentionCount > 0 {
                        Text("\(project.attentionCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Color.orange))
                            .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 6, y: -4)
                    } else if project.workingCount > 0 {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
            Text(memoryPercentText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(project.memoryTier.color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var initialBadge: String {
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let first = parts.first, let second = parts.dropFirst().first {
            return "\(first.prefix(1))\(second.prefix(1))".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    // MARK: Full (default width)

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hover { infoButton }
                statusCounts
            }
            HStack(spacing: 6) {
                Text(project.prettyCwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                memoryReadout
            }
        }
    }

    /// Hover-only "info" button. Opens a popover with heuristic facts about
    /// the project (no LLM calls): per-agent status, last prompt, latest
    /// activity from the parsed JSONL, and process memory.
    private var infoButton: some View {
        Button {
            showInfoPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: ProjectRow.actionButtonSize, height: ProjectRow.actionButtonSize)
                .background(
                    Circle().fill(Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .help("Project info")
        .popover(isPresented: $showInfoPopover, arrowEdge: .leading) {
            ProjectInfoPopover(project: project, onClose: { showInfoPopover = false })
        }
    }

    /// Shared dimension for the round action buttons on a project row so the
    /// info/count chips share the same vertical rhythm.
    static let actionButtonSize: CGFloat = 20

    private var statusCounts: some View {
        HStack(spacing: 6) {
            if project.attentionCount > 0 {
                CountChip(symbol: "hand.raised.fill",
                          count: project.attentionCount,
                          tint: .orange)
            }
            if project.workingCount > 0 {
                CountChip(symbol: "arrow.triangle.2.circlepath",
                          count: project.workingCount,
                          tint: .blue,
                          spinning: true)
            }
            if project.attentionCount == 0 && project.workingCount == 0 {
                CountChip(symbol: "moon.zzz",
                          count: project.sessions.count,
                          tint: .secondary)
            }
        }
    }

    @ViewBuilder
    private var memoryReadout: some View {
        if project.totalMemoryBytes > 0 {
            HStack(spacing: 4) {
                if let pretty = project.prettyTotalMemory {
                    Text(pretty)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(memoryPercentText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(project.memoryTier.color)
                    .monospacedDigit()
            }
        }
    }

    private var memoryPercentText: String {
        let p = project.memoryPercentOfRAM
        if p < 1 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }

    private var rowFill: Color {
        if isActive { return Color.activeHighlight.opacity(0.22) }
        if hover    { return Color.primary.opacity(0.06) }
        return Color.clear
    }
    private var rowStroke: Color {
        if isActive { return Color.activeHighlight.opacity(0.5) }
        return Color.white.opacity(0.04)
    }
}

/// Insights button in the sidebar header. Three visual states:
///
///   • **no insights**   — dormant. Muted outline, no glow.
///   • **unread**        — warm amber, soft outward glow, gentle pulse.
///   • **read** (still present) — muted grey with a subtle residual glow so
///     you can tell something's still in there without it shouting.
///
/// Catch-all drop zone at the bottom of the project list. Hands the moved
/// project to `reorderProject(...)` with `before: nil`, which places it at the
/// end of the sessions array.
private struct EndProjectDropZone: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var isTargeted = false
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                if isTargeted {
                    Rectangle()
                        .fill(Color.activeHighlight)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, raw.hasPrefix("project::") else { return false }
                let movedCwd = String(raw.dropFirst("project::".count))
                hosted.reorderProject(movedCwd: movedCwd, before: nil)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }
}

/// Subtle warm brand gradient — top-left lighter, bottom-right slightly darker.
/// Drives the brand chip and the New Session button so they share a unified
/// surface treatment. Picks up the SwiftUI AccentColor automatically.
enum BrandGradient {
    static var warm: LinearGradient {
        LinearGradient(
            colors: [
                Color.accentColor,
                Color.accentColor.opacity(0.82)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    /// Cool complement to the warm orange accent. Used for "this is selected"
    /// state — active tab outline, active project row tint. Slightly deeper
    /// and more saturated than the system blue used for the "running" status
    /// dot, so the two reads stay distinct.
    static let activeHighlight = Color(red: 0.27, green: 0.46, blue: 0.94)
}

struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

private struct CountChip: View {
    let symbol: String
    let count: Int
    let tint: Color
    var spinning: Bool = false
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(spinning ? rotation : 0))
                .onAppear {
                    guard spinning else { return }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: ProjectRow.actionButtonSize)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
    }
}
