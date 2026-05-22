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
    private var synthesisInflight: Bool = false
    /// Persisted by claudeSessionId so memory survives an app restart and the
    /// agent UUID re-randomizing on restore.
    private var memoryBySessionId: [String: AgentMemory] = [:]
    /// Cross-cutting insights from the LLM. Mixed into the public `insights`
    /// list alongside the heuristic ones.
    private var synthesizedInsights: [Insight] = []
    /// Hash of the last memory snapshot we sent to the LLM, so we don't
    /// re-synthesize when nothing meaningful changed.
    private var lastSynthesizedHash: Int = 0

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

        // LLM-synthesized cross-cutting insights — runs further out so we burn
        // tokens only when project memory has actually settled.
        $projectMemoryByCwd
            .debounce(for: .seconds(45), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.maybeSynthesizeInsights() }
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
            if let title = mem.title { s.aiTitle = title }
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
        // The narrative call also wants the last user prompt for tone (so it can
        // say "You asked …"). Pass it through if we have one.
        let lastUserPrompt = session.lastPrompt
        Task {
            let result = await Self.callAgentMemoryAPI(
                key: key,
                model: model,
                context: context,
                lastUserPrompt: lastUserPrompt
            )
            await MainActor.run {
                self.agentInflight.remove(sid)
                guard let result else { return }
                // The tab title is sticky — generated once on the first user
                // prompt + assistant response, then never revised. The summary
                // and narrative keep evolving.
                let priorTitle = self.agentMemoryByAgentId[sid]?.title
                let finalTitle = priorTitle ?? result.title
                let mem = AgentMemory(
                    cwd: cwd,
                    claudeSessionId: claudeSessionId,
                    title: finalTitle,
                    summary: result.summary,
                    narrative: result.narrative,
                    fingerprint: fingerprint,
                    updatedAt: Date()
                )
                self.agentMemoryByAgentId[sid] = mem
                if let cid = claudeSessionId {
                    self.memoryBySessionId[cid] = mem
                }
                // Only push to the live session if it doesn't already have a title.
                if let live = self.hosted?.session(withId: sid),
                   live.aiTitle == nil || live.aiTitle?.isEmpty == true {
                    live.aiTitle = finalTitle
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

        // Layer LLM-synthesized insights on top of the heuristic ones.
        draft.append(contentsOf: synthesizedInsights)

        // Dedupe by kind+project+agent. Preserve insight identity across
        // recomputes so the popover doesn't churn between "fresh" and "seen".
        var byKey: [String: Insight] = Dictionary(uniqueKeysWithValues: insights.map { ($0.dedupeKey, $0) })
        var out: [Insight] = []
        for insight in draft {
            if let existing = byKey[insight.dedupeKey],
               existing.title == insight.title,
               existing.detail == insight.detail {
                out.append(existing)
            } else {
                unreadInsightCount += 1
                out.append(insight)
            }
        }
        out.sort { insightSortKey($0) < insightSortKey($1) }
        insights = out
        lastInsightsUpdate = now
    }

    // MARK: - LLM-synthesized insights

    private func maybeSynthesizeInsights() {
        guard let hosted, let summarizer, summarizer.hasApiKey, summarizer.enabled else { return }
        guard !synthesisInflight else { return }
        let projects = hosted.projects
        guard !projects.isEmpty else { return }

        // Build the LLM-facing context and a content hash to short-circuit
        // when state hasn't meaningfully changed.
        var bodyLines: [String] = []
        var hasher = Hasher()
        for project in projects {
            bodyLines.append("\n\(project.name) (\(project.prettyCwd))")
            bodyLines.append("- \(project.sessions.count) agent\(project.sessions.count == 1 ? "" : "s")")
            for (idx, s) in project.orderedSessions.enumerated() {
                let statusLabel: String
                switch s.status {
                case .waiting: statusLabel = "Waiting"
                case .running: statusLabel = "Working"
                case .idle:    statusLabel = "Idle"
                case .stale:   statusLabel = "Stale"
                }
                let summary = agentMemoryByAgentId[s.id]?.summary ?? "no memory yet"
                bodyLines.append("- Agent \(idx + 1) (\(statusLabel)): \(summary)")
                hasher.combine(s.id)
                hasher.combine(summary)
                hasher.combine(s.status.rawValue)
            }
        }
        let hash = hasher.finalize()
        if hash == lastSynthesizedHash { return }
        lastSynthesizedHash = hash

        synthesisInflight = true
        let body = bodyLines.joined(separator: "\n")
        let cwds = projects.map { $0.cwd }
        guard let key = summarizer.apiKey else {
            synthesisInflight = false
            return
        }
        let model = summarizer.model
        Task {
            let items = await Self.callSynthesizedInsightsAPI(key: key, model: model, body: body, knownCwds: cwds)
            await MainActor.run {
                self.synthesisInflight = false
                self.synthesizedInsights = items
                self.recomputeInsights()
            }
        }
    }

    private nonisolated static func callSynthesizedInsightsAPI(key: String, model: String, body: String, knownCwds: [String]) async -> [Insight] {
        let system = """
        You're looking at the current state of a developer's Claude Code projects \
        and the rolling summaries of what each agent is doing. Identify up to 3 \
        cross-cutting things worth surfacing — patterns the developer might want \
        to act on now.

        Output a JSON array. Each item is:
        {"kind": "stuck"|"collision"|"info", "title": "<short callout>", "detail": "<optional secondary line>", "cwd": "<the project cwd this is about, or null>"}

        RULES
        - 0 to 3 items. Output [] if nothing notable.
        - DO NOT restate what the developer can already see elsewhere: attention \
        counts, memory pressure %, simple idle time. Those are already surfaced.
        - DO look for: agents converging on the same file or area, repeated \
        failed attempts, completed work that just needs a commit, related work \
        spread across projects, conflicting approaches between agents.
        - Title under 80 chars, detail under 140 chars.
        - "cwd" must be one of the project paths shown to you, exactly, or null.
        - Output ONLY the JSON array. No preamble, no markdown fences.
        """
        guard let raw = await postMessages(key: key, model: model, system: system, user: "Projects:\n\(body)", maxTokens: 400) else {
            return []
        }
        return parseSynthesizedInsights(raw, knownCwds: Set(knownCwds))
    }

    private nonisolated static func parseSynthesizedInsights(_ raw: String, knownCwds: Set<String>) -> [Insight] {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = body.firstIndex(of: "["), let end = body.lastIndex(of: "]") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [Insight] = []
        for obj in arr.prefix(3) {
            let kindStr = (obj["kind"] as? String)?.lowercased() ?? "info"
            let kind: Insight.Kind
            switch kindStr {
            case "stuck":     kind = .stuck
            case "collision": kind = .collision
            default:          kind = .info
            }
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            let detail = (obj["detail"] as? String).flatMap { d -> String? in
                let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            let cwd: String? = {
                guard let c = obj["cwd"] as? String, knownCwds.contains(c) else { return nil }
                return c
            }()
            out.append(Insight(kind: kind, title: title, detail: detail, projectCwd: cwd))
        }
        return out
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

    private nonisolated static func callAgentMemoryAPI(key: String, model: String, context: String, lastUserPrompt: String?) async -> (title: String, summary: String, narrative: String)? {
        let system = """
        You read the LATEST assistant turn from a Claude Code agent and (when \
        provided) the user's most recent prompt. Produce THREE things:

        1. "title" — a snappy 2-to-4-word tab label. Title Case. \
        e.g. "iBeacon detection", "Fix lint errors", "Audio v2 migration".
        2. "summary" — ONE third-person, present-tense sentence (8-16 words) \
        describing what the agent is currently working on. Concrete — name \
        files, tools, or actions when you can.
        3. "narrative" — ONE conversational sentence (10-25 words) framed as \
        either "Claude is …" or "You asked …", whichever fits the latest moment. \
        If Claude has just finished and is awaiting input, use "Claude is asking …" \
        or "Claude is explaining …". Keep it readable; this surfaces in a popover \
        to a developer glancing at the project.

        Output ONLY a JSON object on a single line:
        {"title": "<2-4 words>", "summary": "<one sentence>", "narrative": "<one sentence>"}

        No preamble, no markdown fences, no commentary.

        EXAMPLES

        Agent turn: "Updated VenueManager.swift to add iBeacon detection. About to run xcodebuild."
        Last user prompt: "add iBeacon detection alongside GPS"
        {"title": "iBeacon detection", "summary": "Adding iBeacon detection to VenueManager.swift alongside GPS, about to verify with xcodebuild.", "narrative": "Claude is verifying the iBeacon detection changes by running xcodebuild on VenueManager.swift."}

        Agent turn: "Should we use cosine drift (>0.05) or judge-LLM agreement as the regression signal?"
        Last user prompt: "decide on regression signal"
        {"title": "Regression signal", "summary": "Choosing between cosine drift and judge-LLM agreement as the regression detection signal.", "narrative": "Claude is asking whether to use cosine drift above 0.05 or judge-LLM agreement as the regression signal."}
        """
        let userBody: String
        if let prompt = lastUserPrompt, !prompt.isEmpty {
            userBody = "Last user prompt:\n\(prompt)\n\nLatest assistant turn:\n\(context)"
        } else {
            userBody = "Latest assistant turn:\n\(context)"
        }
        guard let raw = await postMessages(key: key, model: model, system: system, user: userBody, maxTokens: 320) else { return nil }
        return parseAgentMemory(raw)
    }

    /// Tolerant JSON extractor — strips optional ```json fences and finds the
    /// first balanced {...} payload, then pulls title + summary + narrative.
    private nonisolated static func parseAgentMemory(_ raw: String) -> (title: String, summary: String, narrative: String)? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let narrative = (obj["narrative"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !summary.isEmpty, !narrative.isEmpty else { return nil }
        return (title, summary, narrative)
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
