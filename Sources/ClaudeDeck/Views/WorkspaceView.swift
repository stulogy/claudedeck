import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @EnvironmentObject var summarizer: Summarizer

    var body: some View {
        HSplitView {
            ProjectsSidebar()
                .frame(
                    minWidth: ProjectsSidebar.minWidth,
                    idealWidth: ProjectsSidebar.defaultWidth,
                    maxWidth: 480
                )
            TerminalArea()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $summarizer.pendingDraft) { draft in
            DraftReviewSheet(draft: draft)
                .environmentObject(summarizer)
        }
        .sheet(isPresented: Binding(
            get: { hosted.pendingRestore != nil },
            set: { presented in
                // If the sheet dismisses via Escape or background click, treat
                // it the same as "Start fresh" so we don't re-prompt forever.
                if !presented, hosted.pendingRestore != nil {
                    hosted.discardPendingSnapshot()
                }
            }
        )) {
            if let snap = hosted.pendingRestore {
                RestoreSessionsSheet(
                    snapshot: snap,
                    onRestore: { hosted.restorePendingSnapshot() },
                    onDiscard: { hosted.discardPendingSnapshot() }
                )
            }
        }
    }
}

// MARK: - Right side: terminal area

private struct TerminalArea: View {
    @EnvironmentObject var hosted: HostedSessionManager

    var body: some View {
        ZStack {
            terminalBackground
            if hosted.sessions.isEmpty {
                EmptyTerminalState()
            } else if hosted.activeProject == nil {
                NoProjectSelectedState()
            } else {
                VStack(spacing: 0) {
                    tabBar
                    terminalCanvas
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminalBackground: some View {
        LinearGradient(
            colors: [Color(nsColor: .underPageBackgroundColor),
                     Color(nsColor: .windowBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var tabBar: some View {
        if let project = hosted.activeProject {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(project.orderedSessions) { session in
                        TerminalTab(session: session)
                    }
                    NewAgentButton(cwd: project.cwd)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    /// All sessions across all projects are kept alive — invisible ones are
    /// hidden via opacity. Only the active session is interactive.
    private var terminalCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: TerminalPane.terminalBackground))
                .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 6)
            ForEach(hosted.sessions) { s in
                TerminalPane(session: s)
                    .padding(10)
                    .opacity(s.id == hosted.activeSessionId ? 1 : 0)
                    .allowsHitTesting(s.id == hosted.activeSessionId)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: HostedSession
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var hover = false

    var isActive: Bool { hosted.activeSessionId == session.id }

    /// Tab label is either the LLM-generated short title (once we have one) or
    /// just the status. Heuristic mid-turn text isn't a stable identifier — it
    /// flips on every tool call — so we deliberately don't show it here.
    private var tabLabel: String {
        if let t = session.aiTitle, !t.isEmpty { return t }
        switch session.status {
        case .waiting: return "Waiting on you"
        case .running: return "Working…"
        case .idle:    return "Ready"
        case .stale:   return "Stale"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(session.status.color)
                .frame(width: 7, height: 7)
            Text(tabLabel)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
            Button {
                hosted.close(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle().fill(hover ? Color.primary.opacity(0.12) : Color.clear)
                    )
                    .opacity(hover || isActive ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .help("Close agent")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(tooltip)
        .onTapGesture {
            hosted.activeSessionId = session.id
        }
        .onHover { hover = $0 }
    }

    private var tooltip: String {
        var parts: [String] = [tabLabel]
        if let mem = session.memoryPretty { parts.append(mem) }
        return parts.joined(separator: " · ")
    }
}

/// A `+` tab that spawns another agent in the active project's cwd.
private struct NewAgentButton: View {
    let cwd: String
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var hover = false

    var body: some View {
        Button {
            hosted.spawn(cwd: cwd)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hover ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                )
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Add another agent in this project")
        .onHover { hover = $0 }
    }
}

private struct EmptyTerminalState: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 18, x: 0, y: 8)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("Start a session")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Each Claude Code session runs in its own pane,\nstays alive when you switch between them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }
}

private struct NoProjectSelectedState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

// MARK: - New session sheet

struct NewSessionSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var typedPath: String = ""
    @FocusState private var pathFocused: Bool

    private var recents: [String] { hosted.recentCwds }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 28, height: 28)
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("New session")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Path to project")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("/Users/you/Sites/your-project", text: $typedPath)
                        .textFieldStyle(.roundedBorder)
                        .focused($pathFocused)
                    Button { pickFolder() } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(recents.prefix(12), id: \.self) { cwd in
                                RecentRow(cwd: cwd) {
                                    typedPath = cwd
                                    spawn()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    spawn()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("Start session").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!pathLooksValid(typedPath))
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear { pathFocused = true }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: typedPath.isEmpty ? NSHomeDirectory() : typedPath)
        if panel.runModal() == .OK, let url = panel.url { typedPath = url.path }
    }

    private func spawn() {
        let path = expand(typedPath)
        guard pathLooksValid(path) else { return }
        hosted.spawn(cwd: path)
        isPresented = false
    }

    private func expand(_ s: String) -> String {
        s.hasPrefix("~") ? NSHomeDirectory() + s.dropFirst() : s
    }

    private func pathLooksValid(_ s: String) -> Bool {
        let expanded = expand(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !expanded.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }
}

private struct RecentRow: View {
    let cwd: String
    let onPick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProjectNaming.name(forCwd: cwd))
                        .font(.system(size: 12, weight: .semibold))
                    Text(ProjectNaming.prettyCwd(cwd))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
