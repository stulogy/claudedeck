import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @EnvironmentObject var summarizer: Summarizer

    /// Persisted sidebar width. HSplitView in SwiftUI doesn't expose its
    /// divider state, so we drive the width ourselves via @AppStorage and a
    /// custom drag handle.
    @AppStorage("sidebar.width") private var sidebarWidth: Double = Double(ProjectsSidebar.defaultWidth)
    @State private var dragStartWidth: Double = 0
    /// Set when the user presses ⌘W and there's an active agent. Drives the
    /// confirmation alert; cleared when an action is chosen.
    @State private var pendingCloseTab: HostedSession?
    /// Path + body of a markdown file the user ⌘-clicked in the terminal.
    @State private var markdownPreview: (path: String, body: String)?
    /// Project whose transcripts the user wants to browse.
    @State private var transcriptProject: Project?

    private static let sidebarMax: Double = 480

    var body: some View {
        HStack(spacing: 0) {
            ProjectsSidebar()
                .frame(width: CGFloat(sidebarWidth))
            divider
            TerminalArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $summarizer.pendingDraft) { draft in
            DraftReviewSheet(draft: draft)
                .environmentObject(summarizer)
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckNewTab)) { _ in
            // ⌘T spawns another agent in whichever project is currently active.
            // No-op if nothing's active — the user can use ⌘⇧S to pick a project.
            if let project = hosted.activeProject {
                hosted.spawn(cwd: project.cwd)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckCloseTab)) { _ in
            // ⌘W asks for confirmation before terminating the active agent.
            if let session = hosted.activeSession {
                pendingCloseTab = session
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckCycleProject)) { _ in
            hosted.cycleNextProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckCycleTab)) { _ in
            hosted.cycleNextTabInActiveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckOpenPath)) { note in
            guard let raw = note.userInfo?["raw"] as? String else { return }
            handleOpenPath(raw)
        }
        // Whenever the active session changes, send focus to its terminal so
        // the user can type immediately.
        .onChange(of: hosted.activeSessionId) { _, newId in
            if let id = newId { TerminalPane.focusTerminal(sessionId: id) }
        }
        // Returning to the window or the app puts focus back on the active
        // terminal too. Matches the behavior of every real Mac terminal app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let id = hosted.activeSessionId { TerminalPane.focusTerminal(sessionId: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if let id = hosted.activeSessionId { TerminalPane.focusTerminal(sessionId: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeDeckOpenTranscripts)) { note in
            if let project = note.object as? Project {
                transcriptProject = project
            }
        }
        .sheet(isPresented: Binding(
            get: { transcriptProject != nil },
            set: { if !$0 { transcriptProject = nil } }
        )) {
            if let project = transcriptProject {
                TranscriptViewerSheet(
                    project: project,
                    onClose: { transcriptProject = nil }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { markdownPreview != nil },
            set: { if !$0 { markdownPreview = nil } }
        )) {
            if let preview = markdownPreview {
                MarkdownPreviewSheet(
                    path: preview.path,
                    markdown: preview.body,
                    onClose: { markdownPreview = nil }
                )
            }
        }
        .alert(
            "Close this tab?",
            isPresented: Binding(
                get: { pendingCloseTab != nil },
                set: { if !$0 { pendingCloseTab = nil } }
            ),
            presenting: pendingCloseTab
        ) { session in
            Button("Save and Close") {
                hosted.saveAndClose(session)
                pendingCloseTab = nil
            }
            .disabled((session.claudeSessionId ?? "").isEmpty)
            Button("Close", role: .destructive) {
                hosted.close(session)
                pendingCloseTab = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCloseTab = nil
            }
        } message: { session in
            let label = session.aiTitle?.isEmpty == false ? session.aiTitle! : session.displayName
            Text("“\(label)” will be terminated. Choose “Save and Close” to keep it in the restore list for next launch.")
        }
        .sheet(isPresented: Binding(
            get: { hosted.pendingRestore != nil },
            set: { presented in
                // Escape / background dismissal just closes the sheet without
                // wiping the saved snapshot — next launch will offer again.
                // Only the explicit "Start fresh" button discards.
                if !presented, hosted.pendingRestore != nil {
                    hosted.dismissPendingSnapshotPrompt()
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

    /// Handle a link the user Cmd-clicked in the terminal.
    /// - Web URLs go straight to the user's browser.
    /// - Markdown files open in the in-app preview sheet.
    /// - Everything else gets revealed in Finder. That's intentionally simple:
    ///   no guessing at default-app handlers, no risk of the macOS `-50`
    ///   dialog, no Gatekeeper friction. The user can take it from Finder.
    private func handleOpenPath(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var working = trimmed
        if let r = trimmed.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            working = String(trimmed[..<r.lowerBound])
        }
        if let url = URL(string: working), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp", "ssh", "git", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        if working.lowercased().hasPrefix("file://") {
            working = URL(string: working)?.path ?? String(working.dropFirst("file://".count))
        }
        let absolute: String
        if working.hasPrefix("/") {
            absolute = working
        } else if working.hasPrefix("~") {
            absolute = NSHomeDirectory() + String(working.dropFirst())
        } else if let cwd = hosted.activeSession?.cwd {
            absolute = (cwd as NSString).appendingPathComponent(working)
        } else {
            absolute = working
        }
        guard FileManager.default.fileExists(atPath: absolute) else { return }
        if absolute.lowercased().hasSuffix(".md"),
           let body = try? String(contentsOfFile: absolute, encoding: .utf8) {
            markdownPreview = (absolute, body)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
        }
    }

    /// Thin draggable divider between the sidebar and the terminal area.
    /// Persists the new sidebar width as the user drags.
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay(
                // Wider invisible hit area so the cursor change + drag feel
                // forgiving without making the visible divider thick.
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartWidth == 0 {
                                    dragStartWidth = sidebarWidth
                                }
                                let proposed = dragStartWidth + Double(value.translation.width)
                                sidebarWidth = min(max(proposed, Double(ProjectsSidebar.minWidth)), Self.sidebarMax)
                            }
                            .onEnded { _ in dragStartWidth = 0 }
                    )
            )
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
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(project.orderedSessions) { session in
                            TerminalTab(session: session)
                        }
                        NewAgentButton(cwd: project.cwd)
                        // Trailing drop zone — lets users drag a tab past the
                        // last one to move it to the end.
                        EndTabDropZone()
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                }
                .layoutPriority(1)
                ProjectActionsMenu(project: project)
                    .fixedSize()
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 8)
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 18)
                    .opacity(s.id == hosted.activeSessionId ? 1 : 0)
                    .allowsHitTesting(s.id == hosted.activeSessionId)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 10)
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: HostedSession
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var hover = false
    @State private var isDropTarget = false

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
                .fill(isActive ? Color.activeHighlight.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.activeHighlight.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .foregroundStyle(isActive ? Color.activeHighlight : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            // Vertical insertion indicator while a drag is hovering this tab.
            if isDropTarget {
                Rectangle()
                    .fill(Color.activeHighlight)
                    .frame(width: 2)
            }
        }
        .help(tooltip)
        .onTapGesture {
            hosted.activeSessionId = session.id
        }
        .onHover { hover = $0 }
        .draggable(session.id.uuidString) {
            // Drag preview — compact pill so the cursor stays close to the
            // drop point and the underlying tab strip remains visible.
            HStack(spacing: 6) {
                Circle().fill(session.status.color).frame(width: 6, height: 6)
                Text(tabLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.activeHighlight.opacity(0.85))
            )
            .foregroundStyle(.white)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let movedId = UUID(uuidString: raw) else { return false }
            hosted.reorderSession(movedId: movedId, before: session.id)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

    private var tooltip: String {
        var parts: [String] = [tabLabel]
        if let mem = session.memoryPretty { parts.append(mem) }
        return parts.joined(separator: " · ")
    }
}

/// Three-dots menu at the top-right of the tab strip. Project-level actions —
/// closing the project removes ALL its agents and drops it from the sidebar.
/// "Save and Close" parks each agent so the restore sheet offers them on the
/// next launch.
private struct ProjectActionsMenu: View {
    let project: Project
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var hover = false

    private var canPark: Bool {
        project.sessions.contains { ($0.claudeSessionId ?? "").isEmpty == false }
    }

    var body: some View {
        Menu {
            Button {
                for s in project.sessions { hosted.saveAndClose(s) }
            } label: {
                Label("Save and Close Project", systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(!canPark)
            .help(canPark
                  ? "Close every agent in this project but offer to resume them on next launch."
                  : "Nothing to save yet — agents haven't started conversations.")
            Divider()
            Button {
                NotificationCenter.default.post(name: .claudeDeckOpenTranscripts, object: project)
            } label: {
                Label("View Transcripts…", systemImage: "text.bubble")
            }
            Button("Show Folder in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: project.cwd))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.cwd, forType: .string)
            }
            Divider()
            Button(role: .destructive) {
                for s in project.sessions { hosted.close(s) }
            } label: {
                Label("Close Project", systemImage: "xmark.circle.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(hover ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                )
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
        .onHover { hover = $0 }
    }
}

/// Trailing drop zone in the tab strip. Drops here move the dragged agent to
/// the end of the sessions array (within its project), matching how Finder
/// and browsers behave when dragging tabs past the last one.
private struct EndTabDropZone: View {
    @EnvironmentObject var hosted: HostedSessionManager
    @State private var isTargeted = false
    var body: some View {
        // Sized to roughly match a tab's height so it doesn't drag the
        // tab-strip layout taller. (Earlier `maxHeight: .infinity` pushed the
        // outer VStack into a 50/50 split.)
        Rectangle()
            .fill(Color.clear)
            .frame(minWidth: 60, idealWidth: 120, maxWidth: 200)
            .frame(height: 26)
            .overlay(alignment: .leading) {
                if isTargeted {
                    Rectangle()
                        .fill(Color.activeHighlight)
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let movedId = UUID(uuidString: raw) else { return false }
                hosted.reorderSession(movedId: movedId, before: nil)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
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
