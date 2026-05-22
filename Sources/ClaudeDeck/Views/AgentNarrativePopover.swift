import SwiftUI

/// "What just happened?" popover anchored to the sparkles button on a project
/// row. Shows a per-agent narrative line ("Claude is explaining…" / "You asked…")
/// updated on every assistant turn. Different from ProjectMemoryPopover (which
/// shows the rolling synthesized paragraph + concrete agent summaries).
struct AgentNarrativePopover: View {
    let project: Project
    /// (agent, narrative) pairs — only agents with a narrative are passed in.
    let entries: [(agent: HostedSession, narrative: String, title: String?)]
    let onSelectAgent: (HostedSession) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 400)
        .frame(maxHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("What just happened in \(project.name)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, item in
                        AgentNarrativeRow(
                            agent: item.agent,
                            title: item.title,
                            narrative: item.narrative,
                            onSelect: {
                                onSelectAgent(item.agent)
                                onClose()
                            }
                        )
                    }
                }
                .padding(8)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing to summarize yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Once an agent does some work, ClaudeDeck will summarize the last exchange here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

private struct AgentNarrativeRow: View {
    @ObservedObject var agent: HostedSession
    let title: String?
    let narrative: String
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(agent.status.color)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Text(narrative)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
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
