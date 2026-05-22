import SwiftUI

/// Shown on app launch when the previous run had agents open. Lists the projects
/// and agent counts and offers Reopen / Start fresh.
struct RestoreSessionsSheet: View {
    let snapshot: HostedSessionManager.SavedSnapshot
    let onRestore: () -> Void
    let onDiscard: () -> Void

    private var grouped: [(cwd: String, count: Int)] { snapshot.groupedByCwd }
    private var agentCount: Int { snapshot.agents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            summaryLine
            projectsList
            footer
        }
        .padding(22)
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 10, x: 0, y: 4)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off?")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Saved \(RelativeTime.short(from: snapshot.savedAt)) ago")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var summaryLine: some View {
        Text(summaryText)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
    }

    private var summaryText: String {
        let agents = agentCount == 1 ? "1 agent" : "\(agentCount) agents"
        let projects = grouped.count == 1 ? "1 project" : "\(grouped.count) projects"
        return "You had \(agents) open across \(projects). Reopening will resume each conversation where it left off."
    }

    private var projectsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(grouped, id: \.cwd) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ProjectNaming.name(forCwd: item.cwd))
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(ProjectNaming.prettyCwd(item.cwd))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        AgentCountBadge(count: item.count)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxHeight: 240)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Start fresh") { onDiscard() }
                .keyboardShortcut(.cancelAction)
            Button {
                onRestore()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.right")
                    Text("Reopen").fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct AgentCountBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 9, weight: .bold))
            Text(count == 1 ? "1 agent" : "\(count) agents")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.primary.opacity(0.08))
        )
    }
}
