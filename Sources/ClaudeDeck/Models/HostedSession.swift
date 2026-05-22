import Foundation

/// A Claude Code session that ClaudeDeck spawned itself. Owns the pty subprocess
/// (lifecycle in TerminalPane) and exposes derived status from the JSONL Claude
/// writes for it. The status fields are populated by HostedSessionManager's
/// coordinator loop.
@MainActor
final class HostedSession: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    let createdAt: Date
    /// If set, the pty boot command will pass `--resume <id>` to claude. Used
    /// when restoring a previous launch's agents so they continue the same
    /// conversation. Nil for brand-new agents.
    let resumeSessionId: String?

    /// True once the pty subprocess has spawned.
    @Published var isAlive: Bool = false
    /// User-friendly label — defaults to the project folder name.
    @Published var displayName: String

    // MARK: Derived from JSONL (set by the coordinator)
    /// Status inferred from the matched JSONL (waiting / running / idle / stale).
    @Published var status: SessionStatus = .running
    /// Title Claude itself generated for this session (or first prompt snippet).
    @Published var title: String?
    /// Most recent user prompt, sanitised.
    @Published var lastPrompt: String?
    /// Heuristic activity ("Running Bash: …", "Editing X.swift", etc).
    @Published var currentActivity: String?
    /// Last assistant-turn fingerprint, used to cache AI summaries.
    @Published var lastAssistantFingerprint: String?
    /// Compact context we ship to the LLM summarizer / draft endpoint.
    @Published var summarizerContext: String?
    /// Path to the matched JSONL on disk (used for reveal in Finder, etc).
    @Published var jsonlPath: String?
    /// Real Claude session UUID, parsed from the JSONL.
    @Published var claudeSessionId: String?
    /// Last time the JSONL was updated.
    @Published var lastActivity: Date?

    // MARK: Process metadata (set by the pane after spawning)
    /// PID of the spawned pty subprocess. Used to read RSS.
    @Published var processPID: pid_t?
    /// Resident-set size in bytes. Updated by the poll loop.
    @Published var memoryRSS: UInt64?
    /// Pretty-printed memory like "147 MB" — convenience for the UI.
    var memoryPretty: String? {
        guard let rss = memoryRSS, rss > 0 else { return nil }
        let mb = Double(rss) / (1024 * 1024)
        if mb < 1 { return "<1 MB" }
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    init(cwd: String, resumeSessionId: String? = nil) {
        self.cwd = cwd
        self.createdAt = Date()
        self.resumeSessionId = resumeSessionId
        self.displayName = ProjectNaming.name(forCwd: cwd)
    }

    var prettyCwd: String { ProjectNaming.prettyCwd(cwd) }
}

/// Adapter so the existing Summarizer (which takes a `Session`) works with hosted sessions.
extension HostedSession {
    func asSummarizerSubject() -> Session? {
        guard let jsonlPath else { return nil }
        return Session(
            id: claudeSessionId ?? id.uuidString,
            fileURL: URL(fileURLWithPath: jsonlPath),
            cwd: cwd,
            title: title,
            lastPrompt: lastPrompt,
            lastActivity: lastActivity ?? createdAt,
            gitBranch: nil,
            version: nil,
            model: nil,
            status: status,
            messageCount: 0,
            queuedCount: 0,
            entrypoint: .cli,
            currentActivity: currentActivity,
            lastAssistantFingerprint: lastAssistantFingerprint,
            summarizerContext: summarizerContext
        )
    }
}
