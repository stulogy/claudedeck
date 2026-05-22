import SwiftUI

/// Small popover anchored to the project row's info button, showing the rolling
/// "what's going on in this project" paragraph synthesized by MemoryService.
struct ProjectMemoryPopover: View {
    let project: Project
    let memory: ProjectMemory?
    let agentMemories: [AgentMemory]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 380)
        .frame(maxHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(project.prettyCwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let t = memory?.updatedAt {
                Text(RelativeTime.short(from: t))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Last summarized")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let mem = memory, !mem.summary.isEmpty {
                    Text(mem.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    pendingState
                }

                if !agentMemories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agents")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(Array(agentMemories.enumerated()), id: \.offset) { idx, am in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.accentColor.opacity(0.75)))
                                Text(am.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .scrollContentBackground(.hidden)
    }

    private var pendingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No memory yet")
                .font(.system(size: 12, weight: .semibold))
            Text("ClaudeDeck will summarize this project once agents have done some work and the Anthropic API is configured in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
