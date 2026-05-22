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
                    .fill(Color.accentColor)
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
                HStack(spacing: 6) {
                    LightbulbButton()
                    DraftingSpinner()
                }
            } else {
                Spacer(minLength: 0)
                LightbulbButton()
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
                            .fill(Color.accentColor)
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
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, x: 0, y: 4)
            }
        }
        .buttonStyle(.plain)
        .help(compact ? "New session (⌘N)" : "")
        .keyboardShortcut("n", modifiers: .command)
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
    @EnvironmentObject var memory: MemoryService
    @State private var hover = false
    @State private var showMemoryPopover = false
    @State private var showNarrativePopover = false

    private var isActive: Bool { hosted.activeProject?.cwd == project.cwd }
    private var hasMemory: Bool { memory.projectMemoryByCwd[project.cwd] != nil }
    private var hasNarrative: Bool {
        project.sessions.contains { memory.agentMemoryByAgentId[$0.id]?.narrative != nil }
    }
    private var narrativeEntries: [(agent: HostedSession, narrative: String, title: String?)] {
        project.sessions.compactMap { agent in
            guard let mem = memory.agentMemoryByAgentId[agent.id],
                  let narrative = mem.narrative, !narrative.isEmpty else { return nil }
            return (agent, narrative, mem.title)
        }
    }

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
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(compact ? compactTooltip : "")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { hosted.activateProject(project) }
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
                if hover {
                    narrativeButton
                    memoryButton
                }
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

    /// Yellow sparkles — "what just happened?" — opens the narrative popover
    /// for each agent in this project. Hover-only (matches the info button).
    private var narrativeButton: some View {
        Button {
            showNarrativePopover.toggle()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasNarrative ? Color.yellow : Color.secondary)
                .frame(width: ProjectRow.actionButtonSize, height: ProjectRow.actionButtonSize)
                .background(
                    Circle().fill(hasNarrative ? Color.yellow.opacity(0.14) : Color.primary.opacity(0.05))
                )
                .shadow(color: hasNarrative ? Color.yellow.opacity(0.35) : .clear, radius: 4, x: 0, y: 0)
        }
        .buttonStyle(.plain)
        .help(hasNarrative ? "What just happened" : "No recent activity")
        .popover(isPresented: $showNarrativePopover, arrowEdge: .leading) {
            AgentNarrativePopover(
                project: project,
                entries: narrativeEntries,
                onSelectAgent: { agent in hosted.activeSessionId = agent.id },
                onClose: { showNarrativePopover = false }
            )
        }
    }

    /// Small "info" button that opens the project-memory popover. Hover-only.
    private var memoryButton: some View {
        Button {
            showMemoryPopover.toggle()
        } label: {
            Image(systemName: hasMemory ? "sparkle.magnifyingglass" : "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasMemory ? Color.accentColor : .secondary)
                .frame(width: ProjectRow.actionButtonSize, height: ProjectRow.actionButtonSize)
                .background(
                    Circle().fill(hasMemory ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .help(hasMemory ? "Project memory" : "No memory yet")
        .popover(isPresented: $showMemoryPopover, arrowEdge: .leading) {
            ProjectMemoryPopover(
                project: project,
                memory: memory.projectMemoryByCwd[project.cwd],
                agentMemories: project.sessions.compactMap { memory.agentMemoryByAgentId[$0.id] },
                onClose: { showMemoryPopover = false }
            )
        }
    }

    /// Shared dimension for the round action buttons on a project row so the
    /// sparkles/info/count chips all share the same vertical rhythm.
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
                          tint: .blue)
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
        if isActive { return Color.accentColor.opacity(0.20) }
        if hover    { return Color.primary.opacity(0.06) }
        return Color.clear
    }
    private var rowStroke: Color {
        if isActive { return Color.accentColor.opacity(0.45) }
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
/// Uses `sparkles` rather than the older lightbulb glyph — fits the
/// "ClaudeDeck thinks…" framing better than a hardware bulb.
private struct LightbulbButton: View {
    @EnvironmentObject var memory: MemoryService
    @State private var open = false
    @State private var pulse = false

    private var hasInsights: Bool { !memory.insights.isEmpty }
    private var hasUnread: Bool { memory.unreadInsightCount > 0 }

    /// (foreground, glow, ring) — central to the three-state visual.
    private var palette: (fg: Color, glow: Color, ring: Color) {
        if hasUnread {
            return (Color(red: 1.0, green: 0.78, blue: 0.20),
                    Color.yellow.opacity(0.55),
                    Color.yellow.opacity(0.30))
        }
        if hasInsights {
            return (Color.secondary.opacity(0.85),
                    Color.yellow.opacity(0.18),
                    Color.primary.opacity(0.08))
        }
        return (Color.secondary, Color.clear, Color.clear)
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(palette.ring)
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.fg)
                        .shadow(color: palette.glow, radius: hasUnread ? 8 : 4, x: 0, y: 0)
                }
                .scaleEffect(hasUnread && pulse ? 1.06 : 1.0)
                .animation(
                    hasUnread
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                if hasUnread {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(memory.insights.isEmpty ? "No insights" : "\(memory.insights.count) insight\(memory.insights.count == 1 ? "" : "s")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            InsightsPopover(onClose: { open = false })
                .environmentObject(memory)
        }
        .onChange(of: open) { _, isOpen in
            if isOpen { memory.markInsightsRead() }
        }
        .onAppear { pulse = true }
    }
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
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
