import Foundation
import SwiftUI

/// Calls Anthropic's messages API to produce a one-line summary of what a Claude Code
/// session is asking the user. Strictly opt-in: no calls are made unless the user
/// has entered an API key AND toggled summaries on in Settings.
@MainActor
final class Summarizer: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "summaries.enabled") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "summaries.model") }
    }

    /// summary text keyed by sessionId. Updated as background calls return.
    @Published private(set) var summaries: [String: String] = [:]
    /// in-flight summary calls keyed by sessionId, so we don't double-fire.
    @Published private(set) var inflight: Set<String> = []
    /// in-flight draft-response calls keyed by sessionId. Surfaces a spinner in the menu.
    @Published private(set) var inflightDrafts: Set<String> = []
    /// The drafted reply currently being reviewed by the user. UI binds a sheet to this.
    @Published var pendingDraft: PendingDraft?
    /// Last error message (if any) — surfaced in Settings.
    @Published private(set) var lastError: String?
    /// Counters for the lifetime of the app run — also surfaced in Settings.
    @Published private(set) var successCount: Int = 0
    @Published private(set) var failureCount: Int = 0
    @Published private(set) var lastSuccessAt: Date?
    /// Fingerprint of the assistant message we last summarized for this session.
    /// If the fingerprint matches, we don't need to re-summarize.
    private var lastFingerprint: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        self.enabled = d.bool(forKey: "summaries.enabled")
        self.model = d.string(forKey: "summaries.model") ?? "claude-haiku-4-5-20251001"
    }

    var apiKey: String? {
        get { Keychain.get(account: "anthropic.apiKey") }
        set { Keychain.set(newValue, account: "anthropic.apiKey") }
    }
    var hasApiKey: Bool { (apiKey ?? "").count > 10 }

    /// Returns the cached summary if available; otherwise kicks off a request
    /// (when enabled + key present + content non-empty) and returns nil.
    func summary(for session: Session) -> String? {
        guard session.status == .waiting else { return nil }
        if let s = summaries[session.id], lastFingerprint[session.id] == session.lastAssistantFingerprint {
            return s
        }
        request(for: session)
        return summaries[session.id]   // may be stale prior summary while a new one comes in
    }

    /// Fire-and-forget background request. Safe to call repeatedly.
    func request(for session: Session) {
        guard enabled, hasApiKey,
              let context = session.summarizerContext,
              !context.isEmpty,
              let key = apiKey else { return }
        if inflight.contains(session.id) { return }
        if lastFingerprint[session.id] == session.lastAssistantFingerprint,
           summaries[session.id] != nil { return }

        inflight.insert(session.id)
        let model = self.model
        let fingerprint = session.lastAssistantFingerprint ?? UUID().uuidString
        let sid = session.id
        Task {
            let result = await callAPI(key: key, model: model, context: context)
            await MainActor.run {
                self.inflight.remove(sid)
                switch result {
                case .success(let s) where !s.isEmpty:
                    self.summaries[sid] = s
                    self.lastFingerprint[sid] = fingerprint
                    self.successCount += 1
                    self.lastSuccessAt = Date()
                    self.lastError = nil
                case .success:
                    break
                case .failure(let msg):
                    self.failureCount += 1
                    self.lastError = msg
                }
            }
        }
    }

    /// Fire a single test request against a fixed prompt, surface result via lastError/lastSuccessAt.
    func sendTestRequest() {
        guard let key = apiKey else {
            lastError = "No API key on file"
            return
        }
        let testContext = "I've drafted two options for the empty-state copy. Want option A (playful) or option B (direct)?"
        let model = self.model
        Task {
            let result = await callAPI(key: key, model: model, context: testContext)
            await MainActor.run {
                switch result {
                case .success(let s):
                    self.lastSuccessAt = Date()
                    self.lastError = nil
                    self.successCount += 1
                    self.summaries["__test__"] = s
                case .failure(let msg):
                    self.failureCount += 1
                    self.lastError = msg
                }
            }
        }
    }
    var lastTestResult: String? { summaries["__test__"] }

    func clearCache() {
        summaries.removeAll()
        lastFingerprint.removeAll()
    }

    /// Drop the cached summary for one session and immediately re-request.
    func regenerate(for session: Session) {
        summaries.removeValue(forKey: session.id)
        lastFingerprint.removeValue(forKey: session.id)
        request(for: session)
    }

    func isInflight(_ session: Session) -> Bool {
        inflight.contains(session.id)
    }

    // MARK: - HTTP

    enum CallResult {
        case success(String)
        case failure(String)
    }

    // MARK: - Drafting responses

    enum DraftIntent {
        case approve
        case clarify
        case redirect
        case custom(String)

        var label: String {
            switch self {
            case .approve: return "approve / proceed"
            case .clarify: return "ask clarifying question"
            case .redirect: return "push back or change direction"
            case .custom(let n): return "custom: \(n)"
            }
        }
    }

    /// What the user is reviewing: the draft text + which session + which intent
    /// it came from (so the review sheet can offer "Regenerate").
    struct PendingDraft: Identifiable {
        let id = UUID()
        let session: Session
        var intent: DraftIntent
        var text: String
        var generatedAt: Date
    }

    /// Kick off a draft for the user to review. Sets pendingDraft on success.
    func draftReply(for session: Session, intent: DraftIntent) {
        guard let key = apiKey, !key.isEmpty else {
            lastError = "Set your Anthropic API key in Settings first."
            return
        }
        guard let context = session.summarizerContext, !context.isEmpty else {
            lastError = "No assistant message to draft a reply against."
            return
        }
        if inflightDrafts.contains(session.id) { return }
        inflightDrafts.insert(session.id)
        let model = self.model
        let sid = session.id
        Task {
            let result = await callDraftAPI(key: key, model: model, context: context, intent: intent)
            await MainActor.run {
                self.inflightDrafts.remove(sid)
                switch result {
                case .success(let text):
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.pendingDraft = PendingDraft(
                        session: session,
                        intent: intent,
                        text: cleaned,
                        generatedAt: Date()
                    )
                    self.successCount += 1
                    self.lastSuccessAt = Date()
                    self.lastError = nil
                case .failure(let msg):
                    self.failureCount += 1
                    self.lastError = msg
                }
            }
        }
    }

    /// Re-run the draft using the same session + intent. Useful when the user
    /// wants a different phrasing.
    func regenerateCurrentDraft() {
        guard let current = pendingDraft else { return }
        pendingDraft = nil
        draftReply(for: current.session, intent: current.intent)
    }

    func dismissDraft() {
        pendingDraft = nil
    }

    func shortIntent(_ i: DraftIntent) -> String {
        switch i {
        case .approve: return "approve"
        case .clarify: return "clarify"
        case .redirect: return "redirect"
        case .custom: return "custom"
        }
    }

    private nonisolated func callDraftAPI(key: String, model: String, context: String, intent: DraftIntent) async -> CallResult {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 25

        let intentBlock: String
        switch intent {
        case .approve:
            intentBlock = """
            INTENT: The user wants to approve / give the green light to proceed. \
            If the agent presented options A/B/C with no clear winner, pick the most \
            reasonable default and say so.
            """
        case .clarify:
            intentBlock = """
            INTENT: The user wants more info before deciding. Draft a brief, friendly \
            clarifying question that targets the most important unknown.
            """
        case .redirect:
            intentBlock = """
            INTENT: The user wants to redirect the agent to a different approach. \
            Be polite but clear; explain that the proposed path isn't quite right and \
            point at a better direction.
            """
        case .custom(let note):
            intentBlock = """
            INTENT: The user gave this note for the response:
            "\(note)"
            Draft a polished message that conveys this intent in the user's voice.
            """
        }

        let system = """
        You're drafting a reply the user will paste into their Claude Code terminal.

        RULES
        - 1–3 short sentences. Conversational, lowercase OK, no preamble.
        - Sound like a developer talking to their pair programmer, not a customer-service email.
        - Don't restate the agent's question. Don't say "Hi" or "Thanks".
        - No markdown, no quotes around the whole reply, no signature.
        - If asked to approve, just approve clearly ("yes, go ahead with the cosine-drift signal").
        - Output ONLY the reply text.

        \(intentBlock)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 220,
            "system": system,
            "messages": [
                ["role": "user", "content": "Agent message:\n\(context)"]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                return .failure("HTTP \(http.statusCode): \(body.prefix(200))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("Malformed JSON")
            }
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return .failure(msg)
            }
            guard let content = obj["content"] as? [[String: Any]] else {
                return .failure("Missing 'content'")
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            return .success(text)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func isDrafting(_ session: Session) -> Bool {
        inflightDrafts.contains(session.id)
    }

    private nonisolated func callAPI(key: String, model: String, context: String) async -> CallResult {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20

        let system = """
        You read the last message a Claude Code agent posted to its user and write \
        ONE short imperative line describing what the user has to do next.

        RULES
        - 5 to 12 words.
        - Imperative voice ("Approve…", "Pick…", "Confirm…", "Choose…", "Reply with…", "Review…").
        - Never quote the agent. Never paste a fragment. Rewrite the ask in your own words.
        - Never start with a period, a dash, a quote, or any punctuation.
        - End with a question mark only if the line is a literal yes/no question.
        - If the agent is purely informing (no real ask, e.g. just status), output exactly: Awaiting your next prompt
        - Output ONLY the line. No preamble. No JSON. No commentary.

        EXAMPLES

        Agent: "I've drafted two options for the empty-state copy. Want option A (playful) or option B (direct)?"
        You: Choose playful or direct empty-state copy

        Agent: "About to run `rm -rf node_modules && bun install`. OK to proceed?"
        You: Approve a clean node_modules reinstall?

        Agent: "Found 3 candidates for the auth bug. Want me to investigate option 2 (token refresh) first, or all three in parallel?"
        You: Pick option 2, all three, or different order

        Agent: "Done. Ran 47 tests, all green. Pushed to fix/stripe-sigs. Anything else?"
        You: Awaiting your next prompt

        Agent: "Should we use the embedding cosine drift (>0.05) signal, or judge-LLM agreement?"
        You: Pick the regression signal: cosine drift or judge agreement?
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 80,
            "system": system,
            "messages": [
                ["role": "user", "content": "Agent: \"\(context)\"\nYou:"]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                return .failure("HTTP \(http.statusCode): \(body.prefix(200))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("Malformed JSON response")
            }
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return .failure(msg)
            }
            guard let content = obj["content"] as? [[String: Any]] else {
                return .failure("Missing 'content' in response")
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Belt-and-suspenders: strip leading punctuation/quote/dash that some models add.
            while let first = cleaned.first, ".-—\"'`".contains(first) {
                cleaned.removeFirst()
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            // If the model emitted a multi-line response, keep only the first non-empty line.
            if let firstLine = cleaned.split(whereSeparator: \.isNewline).first(where: { !$0.isEmpty }) {
                cleaned = String(firstLine).trimmingCharacters(in: .whitespaces)
            }
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .success(cleaned)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
