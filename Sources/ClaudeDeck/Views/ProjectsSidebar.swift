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
                    .fill(Color.purple.opacity(0.14))
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
                    .fill(LinearGradient(colors: [.accentColor, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
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
                            .fill(LinearGradient(colors: [.accentColor, .purple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        .fill(LinearGradient(colors: [.accentColor, Color.accentColor.opacity(0.85), .purple],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
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
    @State private var hover = false

    private var isActive: Bool { hosted.activeProject?.cwd == project.cwd }

    var body: some View {
        Button {
            hosted.activateProject(project)
        } label: {
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
        }
        .buttonStyle(.plain)
        .help(compact ? compactTooltip : "")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
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
                    Circle().fill(LinearGradient(colors: [.accentColor.opacity(0.9), .purple.opacity(0.85)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
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

/// Yellow lightbulb in the sidebar header. Dormant when there are no insights;
/// glows + pulses when there are unread ones. Opens the `InsightsPopover`.
private struct LightbulbButton: View {
    @EnvironmentObject var memory: MemoryService
    @State private var open = false
    @State private var pulse = false

    private var hasInsights: Bool { !memory.insights.isEmpty }
    private var hasUnread: Bool { memory.unreadInsightCount > 0 }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: hasInsights ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hasInsights ? Color.yellow : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(hasInsights ? Color.yellow.opacity(0.14) : Color.clear)
                    )
                    .scaleEffect(hasUnread && pulse ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                if hasUnread {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
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
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
    }
}
