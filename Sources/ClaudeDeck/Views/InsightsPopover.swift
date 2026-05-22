import SwiftUI

/// The "ClaudeDeck thinks…" popover anchored to the lightbulb in the sidebar
/// header. Lists current heuristic + memory-derived insights, each clickable to
/// focus the relevant project or agent.
struct InsightsPopover: View {
    @EnvironmentObject var memory: MemoryService
    @EnvironmentObject var hosted: HostedSessionManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if memory.insights.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("ClaudeDeck thinks…")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if let t = memory.lastInsightsUpdate {
                Text(RelativeTime.short(from: t))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Last updated")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.green.opacity(0.8))
            Text("All clear")
                .font(.system(size: 13, weight: .semibold))
            Text("No agents need your attention right now.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(memory.insights) { insight in
                    InsightRow(insight: insight) {
                        jump(to: insight)
                        onClose()
                    }
                }
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
    }

    private func jump(to insight: Insight) {
        if let agentId = insight.agentId, hosted.session(withId: agentId) != nil {
            hosted.activeSessionId = agentId
            return
        }
        if let cwd = insight.projectCwd,
           let project = hosted.projects.first(where: { $0.cwd == cwd }) {
            hosted.activateProject(project)
        }
    }
}

private struct InsightRow: View {
    let insight: Insight
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(insight.kind.tint.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: insight.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(insight.kind.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(insight.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let d = insight.detail, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if insight.projectCwd != nil {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
