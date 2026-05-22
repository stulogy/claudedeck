import Foundation
import SwiftUI
import Combine

/// Owns the rolling per-agent + per-project "memory" (short summaries of what
/// each agent / project has been up to), and generates **insights** from those
/// summaries and live state. Insights surface in the lightbulb popover.
///
/// LLM calls reuse the Anthropic key from `Summarizer`. All work is opt-in via
/// the same `summarizer.enabled` toggle in Settings.
@MainActor
final class MemoryService: ObservableObject {
    @Published private(set) var agentMemoryByAgentId: [UUID: AgentMemory] = [:]
    @Published private(set) var projectMemoryByCwd: [String: ProjectMemory] = [:]
    @Published private(set) var insights: [Insight] = []
    /// Goes up whenever the insights set acquires a new entry; reset to 0 when
    /// the user opens the popover.
    @Published private(set) var unreadInsightCount: Int = 0
    @Published private(set) var lastInsightsUpdate: Date?

    private weak var hosted: HostedSessionManager?
    private weak var summarizer: Summarizer?

    private var cancellables = Set<AnyCancellable>()
    private var agentInflight: Set<UUID> = []
    private var projectInflight: Set<String> = []
    /// Persisted by claudeSessionId so memory survives an app restart and the
    /// agent UUID re-randomizing on restore.
    private var memoryBySessionId: [String: AgentMemory] = [:]

    private static let storageKey = "memory.v1"

    init() {
        loadFromDisk()
    }

    func attach(hosted: HostedSessionManager, summarizer: Summarizer) {
        self.hosted = hosted
        self.summarizer = summarizer

        // Per-agent: rehydrate from disk, then trigger summarization when an
        // agent's assistant-turn fingerprint changes. Debounced 2s so we don't
        // hit the API in the middle of a streaming turn.
        hosted.objectWillChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.rehydrateAgentMemories()
                self?.maybeUpdateAgentMemories()
            }
            .store(in: &cancellables)

        // Per-project: synthesize a short paragraph less often (30s debounce).
        hosted.objectWillChange
            .debounce(for: .seconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.maybeUpdateProjectMemories() }
            .store(in: &cancellables)

        // Insights are cheap and rerun on any meaningful change. Heuristic-only
        // for now; LLM-synthesized insights can layer on top later.
        Publishers.Merge3(
            hosted.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            $agentMemoryByAgentId.map { _ in () }.eraseToAnyPublisher(),
            $projectMemoryByCwd.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.recomputeInsights() }
        .store(in: &cancellables)
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        let agentsBySessionId: [String: AgentMemory]
        let projects: [String: ProjectMemory]
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        memoryBySessionId = snap.agentsBySessionId
        projectMemoryByCwd = snap.projects
    }

    private func persist() {
        let snap = Snapshot(
            agentsBySessionId: memoryBySessionId,
            projects: projectMemoryByCwd
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Agent memory

    private func rehydrateAgentMemories() {
        guard let hosted else { return }
        for s in hosted.sessions {
            if agentMemoryByAgentId[s.id] != nil { continue }
            guard let cid = s.claudeSessionId, let mem = memoryBySessionId[cid] else { continue }
            agentMemoryByAgentId[s.id] = mem
        }
    }

    private func maybeUpdateAgentMemories() {
        guard let hosted, let summarizer, summarizer.hasApiKey, summarizer.enabled else { return }
        for s in hosted.sessions {
            guard let context = s.summarizerContext, !context.isEmpty,
                  let fingerprint = s.lastAssistantFingerprint else { continue }
            if let mem = agentMemoryByAgentId[s.id], mem.fingerprint == fingerprint { continue }
            if agentInflight.contains(s.id) { continue }
            startAgentRequest(for: s, context: context, fingerprint: fingerprint)
        }
    }

    private func startAgentRequest(for session: HostedSession, context: String, fingerprint: String) {
        guard let key = summarizer?.apiKey, let model = summarizer?.model else { return }
        agentInflight.insert(session.id)
        let sid = session.id
        let cwd = session.cwd
        let claudeSessionId = session.claudeSessionId
        Task {
            let summary = await Self.callAgentMemoryAPI(key: key, model: model, context: context)
            await MainActor.run {
                self.agentInflight.remove(sid)
                guard let summary, !summary.isEmpty else { return }
                let mem = AgentMemory(
                    cwd: cwd,
                    claudeSessionId: claudeSessionId,
                    summary: summary,
                    fingerprint: fingerprint,
                    updatedAt: Date()
                )
                self.agentMemoryByAgentId[sid] = mem
                if let cid = claudeSessionId {
                    self.memoryBySessionId[cid] = mem
                }
                self.persist()
            }
        }
    }

    // MARK: - Project memory

    private func maybeUpdateProjectMemories() {
        guard let hosted, let summarizer, summarizer.hasApiKey, summarizer.enabled else { return }
        for project in hosted.projects {
            let summaries = project.sessions.compactMap { agentMemoryByAgentId[$0.id]?.summary }
            guard !summaries.isEmpty else { continue }
            let hashes = summaries.map { String($0.hashValue) }
            if let existing = projectMemoryByCwd[project.cwd], existing.agentSummaryHashes == hashes { continue }
            if projectInflight.contains(project.cwd) { continue }
            startProjectRequest(for: project, summaries: summaries, hashes: hashes)
        }
    }

    private func startProjectRequest(for project: Project, summaries: [String], hashes: [String]) {
        guard let key = summarizer?.apiKey, let model = summarizer?.model else { return }
        projectInflight.insert(project.cwd)
        let cwd = project.cwd
        let name = project.name
        Task {
            let paragraph = await Self.callProjectMemoryAPI(key: key, model: model, projectName: name, summaries: summaries)
            await MainActor.run {
                self.projectInflight.remove(cwd)
                guard let paragraph, !paragraph.isEmpty else { return }
                let mem = ProjectMemory(
                    cwd: cwd,
                    summary: paragraph,
                    agentSummaryHashes: hashes,
                    updatedAt: Date()
                )
                self.projectMemoryByCwd[cwd] = mem
                self.persist()
            }
        }
    }

    // MARK: - Insights (heuristic)

    func recomputeInsights() {
        guard let hosted else { return }
        let now = Date()
        var draft: [Insight] = []

        // 1) Attention needed — one row per project. Single waiting agent gets
        // an agentId so the popover row can deep-link to it.
        for project in hosted.projects where project.attentionCount > 0 {
            let waitingAgents = project.sessions.filter { $0.status == .waiting }
            if waitingAgents.count == 1, let agent = waitingAgents.first {
                let mins = max(1, Int(now.timeIntervalSince(agent.lastActivity ?? agent.createdAt) / 60))
                draft.append(Insight(
                    kind: .attention,
                    title: "\(project.name) is waiting on you",
                    detail: "Agent has been waiting ~\(mins) min.",
                    projectCwd: project.cwd,
                    agentId: agent.id
                ))
            } else {
                draft.append(Insight(
                    kind: .attention,
                    title: "\(project.name): \(waitingAgents.count) agents need your input",
                    detail: nil,
                    projectCwd: project.cwd
                ))
            }
        }

        // 2) RAM pressure — only red tier, or amber with 2+ agents.
        for project in hosted.projects {
            let pct = project.memoryPercentOfRAM
            guard pct >= 25 else { continue }
            let isRed = project.memoryTier == .red
            let isAmberWithMultiple = project.memoryTier == .amber && project.sessions.count > 1
            guard isRed || isAmberWithMultiple else { continue }
            draft.append(Insight(
                kind: .ram,
                title: "\(project.name) is using \(Int(pct.rounded()))% of memory",
                detail: project.sessions.count > 1
                    ? "Consider closing an agent you're done with."
                    : "This agent is heavy — consider restarting it.",
                projectCwd: project.cwd
            ))
        }

        // 3) Long-idle but alive agents — looks finished.
        for s in hosted.sessions where s.isAlive && s.status == .idle {
            let idleFor = now.timeIntervalSince(s.lastActivity ?? s.createdAt)
            guard idleFor > 15 * 60 else { continue }
            let mins = Int(idleFor / 60)
            draft.append(Insight(
                kind: .idle,
                title: "\(ProjectNaming.name(forCwd: s.cwd)) agent idle for \(mins) min",
                detail: "Looks finished — close it if so.",
                projectCwd: s.cwd,
                agentId: s.id
            ))
        }

        // Dedupe by kind+project+agent. Preserve insight identity across
        // recomputes so the popover doesn't churn between "fresh" and "seen".
        var byKey: [String: Insight] = Dictionary(uniqueKeysWithValues: insights.map { ($0.dedupeKey, $0) })
        var seen: Set<String> = []
        var out: [Insight] = []
        for insight in draft {
            seen.insert(insight.dedupeKey)
            if let existing = byKey[insight.dedupeKey],
               existing.title == insight.title,
               existing.detail == insight.detail {
                out.append(existing)
            } else {
                unreadInsightCount += 1
                out.append(insight)
            }
        }
        // Drop insights that no longer apply.
        out.sort { insightSortKey($0) < insightSortKey($1) }
        insights = out
        lastInsightsUpdate = now
    }

    private func insightSortKey(_ i: Insight) -> Int {
        switch i.kind {
        case .attention: return 0
        case .stuck:     return 1
        case .collision: return 2
        case .ram:       return 3
        case .idle:      return 4
        case .info:      return 5
        }
    }

    func markInsightsRead() { unreadInsightCount = 0 }

    // MARK: - LLM (Anthropic messages API)

    private nonisolated static func callAgentMemoryAPI(key: String, model: String, context: String) async -> String? {
        let system = """
        You read the LATEST assistant turn from a Claude Code agent and write ONE \
        short third-person sentence describing what the agent is currently working on.

        RULES
        - 8 to 16 words.
        - Third person, present tense ("Refactoring…", "Running…", "Searching…").
        - Concrete: name files, tools, or actions when you can.
        - No quotes, no preamble, no commentary.
        - Output ONLY the sentence.

        EXAMPLES
        Editing VenueManager.swift to add iBeacon detection alongside GPS.
        Running xcodebuild to verify the venue audio v2 migration compiles cleanly.
        Searching the venue_sessions table for rev column inconsistencies.
        """
        return await postMessages(key: key, model: model, system: system, user: "Agent turn:\n\(context)", maxTokens: 80)
    }

    private nonisolated static func callProjectMemoryAPI(key: String, model: String, projectName: String, summaries: [String]) async -> String? {
        let system = """
        You're given a short summary of what each agent in a project is doing. \
        Write a 2–3 sentence paragraph describing the project's current state.

        RULES
        - 2 to 3 sentences. Third person. Concrete.
        - Mention the project name in the first sentence.
        - If agents seem to be doing related or conflicting work, call it out.
        - No preamble, no commentary, no markdown. Output ONLY the paragraph.
        """
        let body = summaries.enumerated().map { i, s in "Agent \(i+1): \(s)" }.joined(separator: "\n")
        return await postMessages(key: key, model: model, system: system, user: "Project: \(projectName)\n\n\(body)", maxTokens: 220)
    }

    private nonisolated static func postMessages(key: String, model: String, system: String, user: String, maxTokens: Int) async -> String? {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else {
                return nil
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
