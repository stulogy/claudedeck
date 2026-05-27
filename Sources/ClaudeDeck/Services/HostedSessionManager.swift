import Foundation
import SwiftUI
import Combine
import AppKit

/// Master brain for hosted sessions. Owns the in-app session list, pairs each
/// one to the JSONL Claude writes (so we can show waiting/running/idle + AI
/// summaries), and polls each pty subprocess for RSS.
@MainActor
final class HostedSessionManager: ObservableObject {
    @Published private(set) var sessions: [HostedSession] = []
    @Published var activeSessionId: UUID?
    @Published private(set) var recentCwds: [String]
    /// Snapshot from the previous launch, if any. UI binds a sheet to this on
    /// startup to ask whether to restore.
    @Published private(set) var pendingRestore: SavedSnapshot?

    private weak var sessionStore: SessionStore?
    private weak var summarizer: Summarizer?

    private var cancellables: Set<AnyCancellable> = []
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private let sessionsDirty = PassthroughSubject<Void, Never>()
    private var memoryTimer: Timer?
    private var statusTimer: Timer?
    /// Remembers which agent the user was last looking at per project, so
    /// clicking a project row returns to that agent (not a status-based pick).
    private var lastActiveAgentByCwd: [String: UUID] = [:]

    private static let recentsKey = "hosted.recentCwds"
    private static let snapshotKey = "hosted.snapshot.v1"
    /// Separate from the live snapshot. Holds agents the user explicitly chose
    /// to "Save and Close" — they should be offered on next launch via the
    /// restore sheet alongside (or instead of) the auto-snapshot.
    private static let parkedKey = "hosted.parked.v1"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        self.recentCwds = stored

        // Load the previous launch's open agents + any parked ("Save and Close")
        // agents. Merge into a single pending-restore offer so the user gets
        // one sheet covering everything that should come back.
        var allSavedAgents: [SavedSnapshot.SavedAgent] = []
        var latestSavedAt: Date?
        if let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
           let snap = try? JSONDecoder().decode(SavedSnapshot.self, from: data) {
            allSavedAgents.append(contentsOf: snap.agents)
            latestSavedAt = snap.savedAt
        }
        if let data = UserDefaults.standard.data(forKey: Self.parkedKey),
           let parked = try? JSONDecoder().decode(SavedSnapshot.self, from: data) {
            // Avoid duplicates if an agent appears in both stores.
            for a in parked.agents where !allSavedAgents.contains(where: { $0.claudeSessionId == a.claudeSessionId && a.claudeSessionId != nil }) {
                allSavedAgents.append(a)
            }
            if let t = latestSavedAt {
                latestSavedAt = max(t, parked.savedAt)
            } else {
                latestSavedAt = parked.savedAt
            }
        }
        if !allSavedAgents.isEmpty {
            self.pendingRestore = SavedSnapshot(agents: allSavedAgents, savedAt: latestSavedAt ?? Date(), activeClaudeSessionId: nil)
        }

        // Coalesce inner-session updates. Each HostedSession publishes many
        // `objectWillChange` events per second (memory poll every 3s + status
        // poll every 5s, each setting multiple @Published properties in a row).
        // Forwarding them all caused click latency because every view bound to
        // the manager was redrawn dozens of times per second. Leading-edge
        // throttle at 200ms keeps the UI live without the avalanche.
        sessionsDirty
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Persist the open-agents snapshot on every relevant change. Debounced
        // so we don't write on every keystroke-level update.
        //
        // CRITICAL: dropFirst() — @Published delivers the current value on
        // subscription, which on cold launch is an empty sessions array. Without
        // dropFirst, the debounced save would fire 500ms later with that empty
        // array and *wipe* the saved snapshot from disk before the user even
        // sees the restore sheet. Only save on genuine changes that happen
        // AFTER launch (spawn / close / restore).
        $sessions
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSnapshot() }
            .store(in: &cancellables)
        sessionsDirty
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSnapshot() }
            .store(in: &cancellables)

        // Backstop: also save when the app is about to quit.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.saveSnapshot() }
            }
            .store(in: &cancellables)

        // Track last-active agent per project so we can return to it.
        $activeSessionId
            .compactMap { $0 }
            .sink { [weak self] id in
                guard let self, let s = self.session(withId: id) else { return }
                self.lastActiveAgentByCwd[s.cwd] = id
            }
            .store(in: &cancellables)
        // Also persist the active-agent change so quitting at any moment
        // remembers which tab the user was on. Same dropFirst guard — the
        // initial value (nil) would otherwise fire a save with an empty
        // sessions array on launch.
        $activeSessionId
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSnapshot() }
            .store(in: &cancellables)

        startPollLoops()
    }

    /// Wire other singletons in once they exist (called from the App).
    func attach(sessionStore: SessionStore, summarizer: Summarizer) {
        self.sessionStore = sessionStore
        self.summarizer = summarizer
        // Refresh whenever the underlying observer picks up a JSONL change.
        sessionStore.$sessions
            .sink { [weak self] _ in self?.refreshStatuses() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    @discardableResult
    func spawn(cwd: String, resumeSessionId: String? = nil, useContinueOnSpawn: Bool = false) -> HostedSession {
        let session = HostedSession(cwd: cwd, resumeSessionId: resumeSessionId, useContinueOnSpawn: useContinueOnSpawn)
        // Forward inner status/memory changes so views observing the manager
        // (project rows that aggregate across sessions) re-render — but route
        // them through the throttled subject above so we don't republish at
        // poll frequency.
        sessionSubscriptions[session.id] = session.objectWillChange
            .sink { [weak self] _ in self?.sessionsDirty.send() }
        sessions.append(session)
        activeSessionId = session.id
        rememberCwd(cwd)
        return session
    }

    func close(_ session: HostedSession) {
        sessionSubscriptions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        if activeSessionId == session.id {
            // Prefer another session in the same project; otherwise fall back.
            let sameProject = sessions.filter { $0.cwd == session.cwd }
            activeSessionId = sameProject.last?.id ?? sessions.last?.id
        }
    }

    /// Terminate the agent like `close(_:)`, but also remember it so the next
    /// launch's restore sheet offers to resume it. Useful when the user wants
    /// to pause work — close the process to free memory but keep the option to
    /// pick up the conversation later via `claude --resume`.
    func saveAndClose(_ session: HostedSession) {
        // Only park if there's a claudeSessionId to resume against. Otherwise
        // there's nothing meaningful to bring back.
        if let cid = session.claudeSessionId, !cid.isEmpty {
            parkAgent(cwd: session.cwd, claudeSessionId: cid, displayName: session.displayName)
        }
        close(session)
    }

    private func parkAgent(cwd: String, claudeSessionId: String, displayName: String) {
        var existing: [SavedSnapshot.SavedAgent] = []
        if let data = UserDefaults.standard.data(forKey: Self.parkedKey),
           let snap = try? JSONDecoder().decode(SavedSnapshot.self, from: data) {
            existing = snap.agents
        }
        // Don't double-park the same conversation.
        existing.removeAll { $0.claudeSessionId == claudeSessionId }
        existing.append(SavedSnapshot.SavedAgent(
            cwd: cwd,
            claudeSessionId: claudeSessionId,
            displayName: displayName
        ))
        let snap = SavedSnapshot(agents: existing, savedAt: Date(), activeClaudeSessionId: nil)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.parkedKey)
        }
    }

    func session(withId id: UUID) -> HostedSession? {
        sessions.first { $0.id == id }
    }

    /// Move `movedId` so it sits immediately before `targetId` in the sessions
    /// list. If `targetId` is nil, the agent moves to the end. Driven by the
    /// tab strip's drag-and-drop. The new order is persisted by the existing
    /// snapshot save pipeline.
    func reorderSession(movedId: UUID, before targetId: UUID?) {
        guard let movingIdx = sessions.firstIndex(where: { $0.id == movedId }) else { return }
        guard movedId != targetId else { return }
        let moving = sessions.remove(at: movingIdx)
        if let targetId, let targetIdx = sessions.firstIndex(where: { $0.id == targetId }) {
            sessions.insert(moving, at: targetIdx)
        } else {
            sessions.append(moving)
        }
    }

    /// Move every agent belonging to `movedCwd` so they sit just before the
    /// first agent of `targetCwd` in the sessions list (relative agent order
    /// inside each project is preserved). When `targetCwd` is nil the project
    /// block moves to the end. Drives the project sidebar drag-and-drop.
    func reorderProject(movedCwd: String, before targetCwd: String?) {
        guard movedCwd != targetCwd else { return }
        let movedSessions = sessions.filter { $0.cwd == movedCwd }
        guard !movedSessions.isEmpty else { return }
        let others = sessions.filter { $0.cwd != movedCwd }
        if let targetCwd, let insertIdx = others.firstIndex(where: { $0.cwd == targetCwd }) {
            var result = others
            result.insert(contentsOf: movedSessions, at: insertIdx)
            sessions = result
        } else {
            sessions = others + movedSessions
        }
    }

    // MARK: - Cycling shortcuts (⌘` / ⌘⇧`)

    /// Cycle the active project to the next one in the sidebar order. Wraps
    /// around at the end. No-op if there's only one project.
    func cycleNextProject() {
        let all = projects
        guard all.count > 1 else { return }
        let activeCwd = activeProject?.cwd
        let currentIdx = all.firstIndex(where: { $0.cwd == activeCwd }) ?? -1
        let nextIdx = (currentIdx + 1) % all.count
        activateProject(all[nextIdx])
    }

    /// Cycle the active agent within the current project. Wraps. No-op if the
    /// active project has fewer than two agents.
    func cycleNextTabInActiveProject() {
        guard let project = activeProject else { return }
        let tabs = project.orderedSessions
        guard tabs.count > 1 else { return }
        let currentIdx = tabs.firstIndex(where: { $0.id == activeSessionId }) ?? -1
        let nextIdx = (currentIdx + 1) % tabs.count
        activeSessionId = tabs[nextIdx].id
    }

    var activeSession: HostedSession? {
        guard let id = activeSessionId else { return nil }
        return session(withId: id)
    }

    // MARK: - Projects (grouped by cwd)

    /// Sessions grouped by working directory in **user-controlled** order. The
    /// underlying `sessions` array is the source of truth; we walk it once and
    /// emit projects in first-encountered-cwd order. Status changes never
    /// reshuffle — only explicit drag-reorder via `reorderProject(...)` does.
    var projects: [Project] {
        var byCwd: [String: [HostedSession]] = [:]
        var orderedCwds: [String] = []
        for s in sessions {
            if byCwd[s.cwd] == nil { orderedCwds.append(s.cwd) }
            byCwd[s.cwd, default: []].append(s)
        }
        return orderedCwds.map { Project(cwd: $0, sessions: byCwd[$0]!) }
    }

    /// The project containing the active session, if any.
    var activeProject: Project? {
        guard let s = activeSession else { return nil }
        return projects.first { $0.cwd == s.cwd }
    }

    /// Make a project active. Focus the agent the user was last looking at in
    /// this project; if that agent no longer exists, fall back to the most
    /// recently active one by JSONL activity.
    func activateProject(_ project: Project) {
        if activeSessionId.flatMap(session(withId:))?.cwd == project.cwd { return }
        // 1) Last clicked agent in this project, if still alive.
        if let lastId = lastActiveAgentByCwd[project.cwd],
           project.sessions.contains(where: { $0.id == lastId }) {
            activeSessionId = lastId
            return
        }
        // 2) Most recently active by JSONL/file activity, else creation time.
        let mostRecent = project.sessions
            .sorted { a, b in
                (a.lastActivity ?? a.createdAt) > (b.lastActivity ?? b.createdAt)
            }
            .first
        if let mostRecent {
            activeSessionId = mostRecent.id
        }
    }

    // MARK: - Session restoration across launches

    /// On-disk snapshot of which agents were open the last time we ran.
    struct SavedSnapshot: Codable {
        let agents: [SavedAgent]
        let savedAt: Date
        /// claudeSessionId of the agent that was focused at save time, so
        /// restoration can return the user to the same tab. Optional for
        /// backward-compat with snapshots written before this field existed.
        let activeClaudeSessionId: String?

        struct SavedAgent: Codable {
            let cwd: String
            /// The claude `--resume` id (the JSONL's sessionId). Optional because
            /// brand-new agents may not have a claudeSessionId yet when saved.
            let claudeSessionId: String?
            let displayName: String
        }

        /// Agents collapsed by cwd for the "you had N agents across M projects" line.
        var groupedByCwd: [(cwd: String, count: Int)] {
            var map: [String: Int] = [:]
            for a in agents { map[a.cwd, default: 0] += 1 }
            return map
                .map { (cwd: $0.key, count: $0.value) }
                .sorted { $0.cwd.localizedCaseInsensitiveCompare($1.cwd) == .orderedAscending }
        }
    }

    /// Spawn each agent in the saved snapshot. The FIRST agent in each cwd
    /// boots with `claude --continue` (loads the most-recent conversation
    /// reliably); subsequent agents in the same cwd boot with the explicit
    /// `--resume <id>` so they don't all converge on the same thread. Cwds
    /// that no longer exist are skipped. After spawning, the agent that was
    /// active at save time becomes active again. Clears the snapshot stores.
    func restorePendingSnapshot() {
        guard let snap = pendingRestore else { return }
        pendingRestore = nil
        UserDefaults.standard.removeObject(forKey: Self.parkedKey)
        let fm = FileManager.default
        var seenCwd: Set<String> = []
        for a in snap.agents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: a.cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            let isFirstForCwd = !seenCwd.contains(a.cwd)
            seenCwd.insert(a.cwd)
            spawn(cwd: a.cwd,
                  resumeSessionId: a.claudeSessionId,
                  useContinueOnSpawn: isFirstForCwd)
        }
        if let activeCsid = snap.activeClaudeSessionId,
           let restored = sessions.first(where: { $0.resumeSessionId == activeCsid }) {
            activeSessionId = restored.id
        }
        saveSnapshot()
    }

    /// Drop the saved snapshot (open + parked) without restoring. Future quits
    /// will save fresh state. Only called for the explicit "Start fresh" button.
    func discardPendingSnapshot() {
        pendingRestore = nil
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        UserDefaults.standard.removeObject(forKey: Self.parkedKey)
    }

    /// Close the restore prompt without touching the saved snapshot. Used
    /// when the user dismisses via Escape or background click — we don't
    /// want to wipe their saved sessions just because they hit the wrong key.
    func dismissPendingSnapshotPrompt() {
        pendingRestore = nil
    }

    private func saveSnapshot() {
        // Prefer the freshly-matched JSONL id, but fall back to the resume id
        // we booted with if matching hasn't completed yet. Without this, a
        // snapshot written within the first 5s of relaunch (before refresh-
        // Statuses fires) drops the id chain and tab titles can't rehydrate.
        let activeCsid = activeSession?.claudeSessionId ?? activeSession?.resumeSessionId
        let snap = SavedSnapshot(
            agents: sessions.map { s in
                SavedSnapshot.SavedAgent(
                    cwd: s.cwd,
                    claudeSessionId: s.claudeSessionId ?? s.resumeSessionId,
                    displayName: s.displayName
                )
            },
            savedAt: Date(),
            activeClaudeSessionId: activeCsid
        )
        if snap.agents.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        } else if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    private func rememberCwd(_ cwd: String) {
        var updated = recentCwds.filter { $0 != cwd }
        updated.insert(cwd, at: 0)
        if updated.count > 20 { updated = Array(updated.prefix(20)) }
        recentCwds = updated
        UserDefaults.standard.set(updated, forKey: Self.recentsKey)
    }

    // MARK: - Coordinator (status + memory)

    private func startPollLoops() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMemory() }
        }
    }

    /// For each hosted session, find the JSONL in ~/.claude/projects/ that
    /// belongs to it. Two agents in the same cwd MUST resolve to different
    /// JSONLs — once an agent has claimed a JSONL by sessionId, that pairing
    /// is sticky, so a younger sibling agent can't poach the same file just
    /// because it was touched more recently.
    func refreshStatuses() {
        guard let store = sessionStore else { return }
        // Bucket all observed sessions by cwd for O(N) lookup.
        let observed = store.sessions
        var byCwd: [String: [Session]] = [:]
        for s in observed { byCwd[s.cwd, default: []].append(s) }

        // JSONL ids already paired to a hosted agent — don't reassign them.
        var claimedJsonlIds = Set<String>()
        for hosted in sessions {
            if let cid = hosted.claudeSessionId { claimedJsonlIds.insert(cid) }
        }

        // Resolve oldest-spawned agents first so they get first dibs on the
        // matching JSONL (the JSONL that was created closest to their spawn time).
        let hostedSorted = sessions.sorted { $0.createdAt < $1.createdAt }

        for hosted in hostedSorted {
            let candidates = byCwd[hosted.cwd] ?? []
            let matched: Session?
            if let cid = hosted.claudeSessionId {
                // Sticky: stay paired to the same JSONL across refreshes.
                matched = candidates.first { $0.id == cid }
            } else {
                // First-time pairing: take the most recent JSONL whose file
                // activity is at/after our spawn AND that no other hosted
                // agent has already claimed.
                matched = candidates
                    .filter { $0.lastActivity >= hosted.createdAt.addingTimeInterval(-2) }
                    .filter { !claimedJsonlIds.contains($0.id) }
                    .sorted { $0.lastActivity > $1.lastActivity }
                    .first
                if let m = matched { claimedJsonlIds.insert(m.id) }
            }
            guard let m = matched else {
                // No JSONL yet. Don't show a misleading "Starting…" forever —
                // the tab label falls through to the status text. Within the
                // first ~3 seconds of spawning we DO show "Starting…" since the
                // pty really is booting; after that it's just an idle splash.
                let age = Date().timeIntervalSince(hosted.createdAt)
                if age < 3 && hosted.title == nil {
                    hosted.currentActivity = "Starting…"
                } else if hosted.currentActivity == "Starting…" {
                    hosted.currentActivity = nil
                }
                continue
            }
            hosted.claudeSessionId = m.id
            hosted.jsonlPath = m.fileURL.path
            hosted.status = m.status
            hosted.title = m.title
            hosted.lastPrompt = m.lastPrompt
            hosted.currentActivity = m.currentActivity
            hosted.lastAssistantFingerprint = m.lastAssistantFingerprint
            hosted.summarizerContext = m.summarizerContext
            hosted.lastActivity = m.lastActivity
            hosted.userMessageCount = m.userMessageCount
            // No auto-fire of Summarizer.request — MemoryService already
            // produces the narrative line per fingerprint change in a single
            // bundled call (title + summary + narrative), so the standalone
            // "what to do next" summary is duplicate work. The Summarizer is
            // still used on-demand for draft replies.
        }
    }

    func refreshMemory() {
        for hosted in sessions {
            guard let pid = hosted.processPID, pid > 0 else { continue }
            hosted.memoryRSS = ProcessMemory.residentBytesIncludingChildren(pid: pid)
        }
    }

    // MARK: - Claude binary

    static func resolveClaudePath() -> String? {
        if let override = UserDefaults.standard.string(forKey: "hosted.claudePath"),
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.nvm/versions/node/v20/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }
}
