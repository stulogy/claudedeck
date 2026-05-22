import SwiftUI

/// Compact menubar dropdown — lists hosted sessions only, click to focus the
/// main window with that session active.
struct MenuBarView: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill").foregroundStyle(.tint)
                Text("ClaudeDeck")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "ClaudeDeck")
                } label: {
                    Image(systemName: "rectangle.expand.diagonal")
                }
                .buttonStyle(.plain)
                .help("Open dashboard")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            HStack(spacing: 8) {
                StatCell(label: "Waiting", count: waitingCount, color: .orange)
                StatCell(label: "Running", count: runningCount, color: .blue)
                StatCell(label: "Idle", count: idleCount, color: .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if hosted.sessions.isEmpty {
                        Text("No sessions yet — open the app to start one.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(hosted.sessions) { session in
                            MenuBarRow(session: session)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 360)

            Divider()

            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "ClaudeDeck")
                } label: {
                    Label("Open ClaudeDeck", systemImage: "rectangle.stack")
                }
                .buttonStyle(.plain)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Text("Quit").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private var waitingCount: Int { hosted.sessions.filter { $0.status == .waiting }.count }
    private var runningCount: Int { hosted.sessions.filter { $0.status == .running }.count }
    private var idleCount: Int { hosted.sessions.filter { $0.status == .idle }.count }
}

private struct StatCell: View {
    let label: String
    let count: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Text("\(count)").font(.system(size: 18, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial)
        )
    }
}

private struct MenuBarRow: View {
    @ObservedObject var session: HostedSession
    @EnvironmentObject var hosted: HostedSessionManager
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false

    var body: some View {
        Button {
            hosted.activeSessionId = session.id
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "ClaudeDeck")
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.prettyCwd)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let mem = session.memoryPretty {
                            Text(mem)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
