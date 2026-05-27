import SwiftUI

/// Heuristic, no-LLM project info popover. Shown when the user clicks the
/// (i) button on a project row. Pulls everything from `HostedSession` state
/// that's already populated by the JSONL parser — last user prompt, latest
/// activity, status, process memory.
struct ProjectInfoPopover: View {
    let project: Project
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 420)
        .frame(maxHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(project.prettyCwd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let mem = project.prettyTotalMemory {
                Text("\(mem) · \(Int(project.memoryPercentOfRAM.rounded()))%")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(project.memoryTier.color)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(project.orderedSessions.enumerated()), id: \.element.id) { item in
                    AgentRow(index: item.offset + 1, agent: item.element)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct AgentRow: View {
    let index: Int
    @ObservedObject var agent: HostedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(agent.status.color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(timeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let prompt = agent.lastPrompt, !prompt.isEmpty {
                Label {
                    Text(prompt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            if let activity = agent.currentActivity, !activity.isEmpty {
                Label {
                    Text(activity)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 10) {
                Text(agent.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(agent.status.color)
                if let mem = agent.memoryPretty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(mem)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    private var title: String {
        if let t = agent.aiTitle, !t.isEmpty { return t }
        if let t = agent.title, !t.isEmpty { return t }
        return "Agent \(index)"
    }

    private var timeText: String {
        let when = agent.lastActivity ?? agent.createdAt
        return RelativeTime.short(from: when)
    }
}
