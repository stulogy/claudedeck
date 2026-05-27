import Foundation

/// Parses a Claude Code session .jsonl file and returns a `Session` snapshot.
/// Strategy: read the file as raw lines from the END backwards looking for key entries
/// (last assistant turn, last user turn, ai-title, last-prompt). Falls back to forward
/// scan if needed. Keeps memory low — we never load the whole file into Strings.
enum SessionParser {

    static let idleThreshold: TimeInterval = 60 * 5        // 5 min
    static let staleThreshold: TimeInterval = 60 * 60 * 24 // 1 day

    static func parse(fileURL: URL) -> Session? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileMTime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        var sessionId: String?
        var cwd: String?
        var gitBranch: String?
        var version: String?
        var model: String?
        var aiTitle: String?
        var lastPrompt: String?
        var firstUserPrompt: String?
        var entrypointRaw: String?
        var lastEntryTimestamp: Date?
        var lastAssistantStopReason: String?
        var lastAssistantHadTextOutput = false
        var lastAssistantHadToolUse = false
        var lastUserHadOnlyToolResults = false
        var lastEventWasAssistant = false
        var lastEventWasUser = false
        var messageCount = 0
        var userMessageCount = 0
        var queuedCount = 0
        var lastAssistantText: String = ""
        var lastAssistantToolName: String?
        var lastAssistantToolBrief: String?
        var lastAssistantUUID: String?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String) -> Date? {
            iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        // Forward scan. Files are append-only so the last assistant/user entries
        // we see are by definition the most recent.
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            let count = buf.count
            let bytes = base.assumingMemoryBound(to: UInt8.self)

            for i in 0..<count {
                if bytes[i] == 0x0A { // newline
                    let lineData = Data(bytes: bytes.advanced(by: start), count: i - start)
                    start = i + 1
                    processLine(lineData)
                }
            }
            if start < count {
                let lineData = Data(bytes: bytes.advanced(by: start), count: count - start)
                processLine(lineData)
            }
        }

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }
            let type = obj["type"] as? String ?? ""

            if sessionId == nil, let sid = obj["sessionId"] as? String { sessionId = sid }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            if let v = obj["version"] as? String { version = v }
            if let ep = obj["entrypoint"] as? String { entrypointRaw = ep }

            if let ts = obj["timestamp"] as? String, let d = parseDate(ts) {
                if lastEntryTimestamp == nil || d > lastEntryTimestamp! {
                    lastEntryTimestamp = d
                }
            }

            switch type {
            case "ai-title":
                if let t = obj["aiTitle"] as? String { aiTitle = t }
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String { lastPrompt = p }
            case "user":
                messageCount += 1
                lastEventWasAssistant = false
                lastEventWasUser = true
                lastAssistantStopReason = nil
                let (text, onlyToolResults) = extractUserText(obj)
                lastUserHadOnlyToolResults = onlyToolResults
                if let raw = text {
                    let cleaned = sanitize(raw)
                    if !cleaned.isEmpty {
                        if firstUserPrompt == nil { firstUserPrompt = cleaned }
                        if !onlyToolResults {
                            lastPrompt = cleaned
                            userMessageCount += 1
                        }
                    }
                }
            case "assistant":
                messageCount += 1
                lastEventWasAssistant = true
                lastEventWasUser = false
                lastAssistantUUID = obj["uuid"] as? String
                if let msg = obj["message"] as? [String: Any] {
                    if let m = msg["model"] as? String { model = m }
                    lastAssistantStopReason = msg["stop_reason"] as? String
                    var hasText = false
                    var hasToolUse = false
                    var textPieces: [String] = []
                    var toolName: String?
                    var toolBrief: String?
                    if let content = msg["content"] as? [[String: Any]] {
                        for c in content {
                            let ct = c["type"] as? String
                            if ct == "text" {
                                if let s = c["text"] as? String, !s.isEmpty {
                                    hasText = true
                                    textPieces.append(s)
                                }
                            } else if ct == "tool_use" {
                                hasToolUse = true
                                let n = c["name"] as? String
                                toolName = n
                                if let input = c["input"] as? [String: Any] {
                                    toolBrief = describeToolInput(name: n, input: input)
                                }
                            }
                        }
                    }
                    lastAssistantHadTextOutput = hasText
                    lastAssistantHadToolUse = hasToolUse
                    lastAssistantText = sanitize(textPieces.joined(separator: "\n"))
                    lastAssistantToolName = toolName
                    lastAssistantToolBrief = toolBrief
                }
            case "queue-operation":
                if let op = obj["operation"] as? String {
                    if op == "enqueue" { queuedCount += 1 }
                    else if op == "dequeue" || op == "remove" { queuedCount = max(0, queuedCount - 1) }
                }
            default:
                break
            }
        }

        guard let sid = sessionId, let workingDir = cwd else { return nil }

        let activity = lastEntryTimestamp ?? fileMTime
        let age = Date().timeIntervalSince(activity)

        // Status inference.
        let status: SessionStatus
        if age > staleThreshold {
            status = .stale
        } else if firstUserPrompt == nil {
            // Brand-new session sitting at the Claude Code splash — no user
            // prompt yet means nothing is actually awaiting the user, even if
            // an assistant boilerplate entry has been written with end_turn.
            status = .idle
        } else if lastEventWasAssistant {
            // Assistant spoke last. If tool_use stop reason and no following tool_result,
            // a tool is in flight (Claude awaiting tool to come back, or compute running).
            if lastAssistantStopReason == "tool_use" && lastAssistantHadToolUse {
                // Long silence on a tool_use entry usually means the TUI is
                // showing a permission prompt waiting on the user. Real
                // long-running tools stream output that bumps the JSONL mtime;
                // a blocked permission prompt sits silent. 30s is a safe gap.
                if age > 30 {
                    status = age < staleThreshold ? .waiting : .idle
                } else {
                    status = age < idleThreshold ? .running : .idle
                }
            } else {
                // end_turn / stop_sequence — model handed control back to the user.
                status = age < staleThreshold ? .waiting : .idle
            }
        } else if lastEventWasUser {
            // Tool-result-only tail: the tool loop closed but claude didn't
            // emit a follow-up assistant turn (typical for slash commands
            // like /compact, /clear, /memory — they hand control straight
            // back to the user). Treat as idle once the dust settles so the
            // tab doesn't say "Working…" forever.
            if lastUserHadOnlyToolResults {
                // Within the first few seconds claude might still be composing
                // a response; after that it's safe to call this idle.
                status = age < 5 ? .running : .idle
            } else {
                // Real prompt — claude is thinking / typing.
                status = age < idleThreshold ? .running : .idle
            }
        } else {
            status = age < idleThreshold ? .running : .idle
        }

        let title = aiTitle ?? firstUserPrompt.map { snippet($0, max: 60) }

        // Build the heuristic "current activity" string.
        let activityText: String?
        switch status {
        case .running:
            if let brief = lastAssistantToolBrief {
                activityText = brief
            } else if let name = lastAssistantToolName {
                activityText = "Running \(name)"
            } else if lastEventWasUser {
                activityText = "Thinking…"
            } else {
                activityText = nil
            }
        case .waiting:
            if !lastAssistantText.isEmpty {
                activityText = lastSentence(lastAssistantText, max: 140)
            } else if let name = lastAssistantToolName {
                activityText = "Asks to run \(name)"
            } else {
                activityText = nil
            }
        case .idle, .stale:
            activityText = nil
        }

        // Summarizer input (for the optional LLM call).
        var summarizerPieces: [String] = []
        if !lastAssistantText.isEmpty {
            summarizerPieces.append(lastAssistantText.prefix(1500).description)
        }
        if let toolName = lastAssistantToolName {
            var s = "[Tool call: \(toolName)"
            if let b = lastAssistantToolBrief { s += " — \(b)" }
            s += "]"
            summarizerPieces.append(s)
        }
        let summarizerContext = summarizerPieces.isEmpty ? nil : summarizerPieces.joined(separator: "\n")

        return Session(
            id: sid,
            fileURL: fileURL,
            cwd: workingDir,
            title: title,
            lastPrompt: lastPrompt.map { snippet($0, max: 240) },
            lastActivity: activity,
            gitBranch: gitBranch,
            version: version,
            model: model,
            status: status,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            queuedCount: queuedCount,
            entrypoint: SessionEntrypoint(raw: entrypointRaw),
            currentActivity: activityText,
            lastAssistantFingerprint: lastAssistantUUID,
            summarizerContext: summarizerContext
        )
    }

    /// Compact human description of a tool call's intent. e.g.
    ///   Bash {command: "npm test"} → "Running Bash: npm test"
    ///   Edit {file_path: "/foo/bar.swift"} → "Editing bar.swift"
    ///   Read {file_path: "/foo/bar.md"} → "Reading bar.md"
    private static func describeToolInput(name: String?, input: [String: Any]) -> String? {
        guard let n = name else { return nil }
        switch n {
        case "Bash":
            if let cmd = input["command"] as? String {
                return "Running Bash: " + snippet(cmd, max: 80)
            }
            return "Running Bash"
        case "Edit":
            if let p = input["file_path"] as? String {
                return "Editing \(URL(fileURLWithPath: p).lastPathComponent)"
            }
            return "Editing file"
        case "Write":
            if let p = input["file_path"] as? String {
                return "Writing \(URL(fileURLWithPath: p).lastPathComponent)"
            }
            return "Writing file"
        case "Read":
            if let p = input["file_path"] as? String {
                return "Reading \(URL(fileURLWithPath: p).lastPathComponent)"
            }
            return "Reading file"
        case "Grep":
            if let pat = input["pattern"] as? String {
                return "Searching for \"\(snippet(pat, max: 50))\""
            }
            return "Searching"
        case "WebSearch":
            if let q = input["query"] as? String {
                return "Searching web: " + snippet(q, max: 60)
            }
            return "Searching the web"
        case "WebFetch":
            if let u = input["url"] as? String {
                return "Fetching \(u)"
            }
            return "Fetching URL"
        case "Agent":
            if let d = input["description"] as? String {
                return "Delegating: " + snippet(d, max: 60)
            }
            return "Delegating to subagent"
        default:
            // Generic fallback — find any string-valued key with sensible content.
            if let p = input["file_path"] as? String {
                return "\(n): \(URL(fileURLWithPath: p).lastPathComponent)"
            }
            if let c = input["command"] as? String {
                return "\(n): \(snippet(c, max: 60))"
            }
            return "Running \(n)"
        }
    }

    /// Strip Claude Code system-internal tags like
    ///   <local-command-stdout>…</local-command-stdout>
    ///   <command-name>…</command-name>
    /// which leak into the visible prompt/last-message text. Returns a trimmed string.
    static func sanitize(_ s: String) -> String {
        var out = s
        // Match any <local-*>…</local-*>, <command-*>…</command-*>, <bash-*>…</bash-*>,
        // or <system-reminder>…</system-reminder> using a backreference so we don't
        // need to enumerate every variant Claude Code adds over time.
        let patterns = [
            "<((?:local|command|bash)-[^>\\s]+)>[\\s\\S]*?</\\1>",
            "<(system-reminder)>[\\s\\S]*?</\\1>"
        ]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let range = NSRange(out.startIndex..., in: out)
                out = r.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
            }
        }
        // Strip any leftover dangling tags (open or close) — sometimes content includes
        // a stray <local-command-caveat> opener without a close in our window.
        if let r = try? NSRegularExpression(pattern: "</?(?:local|command|bash)-[^>]*>", options: [.caseInsensitive]) {
            let range = NSRange(out.startIndex..., in: out)
            out = r.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
        }
        // Collapse multiple blank lines.
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the last 1–2 sentences out of a longer block of text.
    private static func lastSentence(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find last sentence-ending punctuation, keep ~1-2 sentences worth.
        let scalars = Array(trimmed)
        guard !scalars.isEmpty else { return "" }
        var cut = scalars.count
        var sentences = 0
        for i in stride(from: scalars.count - 2, through: 0, by: -1) {
            let c = scalars[i]
            if c == "." || c == "?" || c == "!" || c == "\n" {
                sentences += 1
                if sentences >= 2 {
                    cut = i + 1
                    break
                }
            }
        }
        let tail = String(scalars[cut..<scalars.count]).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty {
            return snippet(trimmed, max: max)
        }
        return snippet(tail, max: max)
    }

    /// Returns (text, onlyToolResults). A user entry can be a plain string content,
    /// or an array of content blocks (some of which are tool_result blocks).
    private static func extractUserText(_ obj: [String: Any]) -> (String?, Bool) {
        guard let msg = obj["message"] as? [String: Any] else { return (nil, false) }
        if let s = msg["content"] as? String {
            return (s, false)
        }
        if let arr = msg["content"] as? [[String: Any]] {
            var pieces: [String] = []
            var sawNonToolResult = false
            for c in arr {
                let ct = c["type"] as? String
                if ct == "tool_result" {
                    continue
                }
                sawNonToolResult = true
                if let s = c["text"] as? String { pieces.append(s) }
            }
            let onlyToolResults = !sawNonToolResult
            return (pieces.joined(separator: "\n"), onlyToolResults)
        }
        return (nil, false)
    }

    private static func snippet(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: max)
        return trimmed[..<idx] + "…"
    }
}
