import SwiftUI
import AppKit

/// Reads the raw JSONL transcripts Claude Code writes to
/// `~/.claude/projects/<escaped-cwd>/` and renders them as a conversation.
/// The user picks which transcript (most projects accumulate multiple as
/// `--resume`/`--continue` fork new sessions). Tool-use turns collapse to a
/// short label so the eye lands on the user/assistant text.
struct TranscriptViewerSheet: View {
    let project: Project
    let onClose: () -> Void

    @State private var sessions: [TranscriptSession] = []
    @State private var selectedSessionId: String?
    @State private var turns: [Turn] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                sessionList
                Divider()
                transcript
            }
        }
        .frame(width: 920, height: 680)
        .onAppear(perform: loadSessions)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcripts — \(project.name)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(project.prettyCwd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sessions) { s in
                    Button {
                        selectedSessionId = s.id
                        loadTurns(for: s)
                    } label: {
                        sessionRow(for: s)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
        .background(Color.primary.opacity(0.03))
    }

    private func sessionRow(for s: TranscriptSession) -> some View {
        let isSelected = s.id == selectedSessionId
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title ?? "Untitled session")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(s.userTurns) prompts")
                        .font(.system(size: 10, weight: .medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text(sizeLabel(s.fileSize))
                        .font(.system(size: 10))
                    Text("·").foregroundStyle(.tertiary)
                    Text(RelativeTime.short(from: s.lastModified))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.activeHighlight.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.activeHighlight.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var transcript: some View {
        if loading {
            VStack { ProgressView().controlSize(.small) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if turns.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(sessions.isEmpty ? "No transcripts for this project yet"
                                       : "Pick a session on the left to view its transcript")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        turnView(turn)
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        HStack(alignment: .top, spacing: 12) {
            roleBadge(turn.role)
            VStack(alignment: .leading, spacing: 4) {
                Text(turn.role.label)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if turn.role == .tool {
                    Text(turn.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                } else {
                    Text(.init(turn.text))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func roleBadge(_ role: Role) -> some View {
        Circle()
            .fill(role.tint.opacity(0.18))
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: role.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(role.tint)
            )
    }

    // MARK: - Loading

    private func loadSessions() {
        let escaped = "-" + project.cwd.replacingOccurrences(of: "/", with: "-")
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".claude/projects")
            .appending(path: escaped, directoryHint: .isDirectory)
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter({ $0.pathExtension == "jsonl" }) else {
            sessions = []
            return
        }
        var loaded: [TranscriptSession] = []
        for url in files {
            if let s = TranscriptSession.scan(url: url) { loaded.append(s) }
        }
        // Sort by richness — busiest sessions first; the user's "lost"
        // conversation is usually the largest in the directory.
        loaded.sort { $0.userTurns > $1.userTurns }
        sessions = loaded
        if let first = loaded.first {
            selectedSessionId = first.id
            loadTurns(for: first)
        }
    }

    private func loadTurns(for session: TranscriptSession) {
        loading = true
        let url = session.fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = Turn.parseAll(jsonlPath: url.path)
            DispatchQueue.main.async {
                self.turns = parsed
                self.loading = false
            }
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Data types

struct TranscriptSession: Identifiable {
    let id: String         // jsonl sessionId (filename minus .jsonl)
    let fileURL: URL
    let title: String?
    let userTurns: Int
    let fileSize: Int
    let lastModified: Date

    static func scan(url: URL) -> TranscriptSession? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let id = url.deletingPathExtension().lastPathComponent
        var firstUser: String?
        var userCount = 0
        if let stream = InputStream(url: url) {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let chunkSize = 64 * 1024
            var raw = [UInt8](repeating: 0, count: chunkSize)
            while stream.hasBytesAvailable {
                let n = stream.read(&raw, maxLength: chunkSize)
                if n <= 0 { break }
                buffer.append(raw, count: n)
                if firstUser != nil && userCount > 200 { break }  // upper bound; we just need a count for the list
            }
            for line in buffer.split(separator: 0x0A) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "user", let txt = Self.firstUserText(in: obj), !txt.isEmpty {
                    if firstUser == nil { firstUser = txt }
                    userCount += 1
                }
            }
        }
        let title: String? = firstUser.map { snip in
            let trimmed = snip.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 70 ? String(trimmed.prefix(70)) + "…" : trimmed
        }
        return TranscriptSession(
            id: id,
            fileURL: url,
            title: title,
            userTurns: userCount,
            fileSize: size,
            lastModified: mtime
        )
    }

    private static func firstUserText(in obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] {
            for c in arr where (c["type"] as? String) == "text" {
                if let t = c["text"] as? String, !t.isEmpty { return t }
            }
        }
        return nil
    }
}

enum Role {
    case user, assistant, tool

    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Claude"
        case .tool: return "Tool call"
        }
    }
    var symbol: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver"
        }
    }
    var tint: Color {
        switch self {
        case .user: return .accentColor
        case .assistant: return .activeHighlight
        case .tool: return .secondary
        }
    }
}

struct Turn: Identifiable {
    let id = UUID()
    let role: Role
    let text: String

    static func parseAll(jsonlPath: String) -> [Turn] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath), options: [.mappedIfSafe]) else {
            return []
        }
        var out: [Turn] = []
        for lineData in data.split(separator: 0x0A) {
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "user":
                if let txt = extractText(obj), !txt.isEmpty {
                    out.append(Turn(role: .user, text: txt))
                }
            case "assistant":
                let (text, toolBrief) = extractAssistant(obj)
                if let text, !text.isEmpty {
                    out.append(Turn(role: .assistant, text: text))
                }
                if let brief = toolBrief, !brief.isEmpty {
                    out.append(Turn(role: .tool, text: brief))
                }
            default:
                continue
            }
        }
        return out
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] {
            var pieces: [String] = []
            for c in arr {
                if (c["type"] as? String) == "text", let t = c["text"] as? String { pieces.append(t) }
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        }
        return nil
    }

    private static func extractAssistant(_ obj: [String: Any]) -> (text: String?, toolBrief: String?) {
        guard let msg = obj["message"] as? [String: Any] else { return (nil, nil) }
        var textPieces: [String] = []
        var toolBriefs: [String] = []
        if let arr = msg["content"] as? [[String: Any]] {
            for c in arr {
                switch c["type"] as? String {
                case "text":
                    if let t = c["text"] as? String, !t.isEmpty { textPieces.append(t) }
                case "tool_use":
                    let name = (c["name"] as? String) ?? "tool"
                    var detail: String?
                    if let input = c["input"] as? [String: Any] {
                        if let cmd = input["command"] as? String {
                            detail = cmd
                        } else if let path = input["file_path"] as? String {
                            detail = URL(fileURLWithPath: path).lastPathComponent
                        } else if let pattern = input["pattern"] as? String {
                            detail = pattern
                        }
                    }
                    if let detail {
                        toolBriefs.append("\(name): \(detail)".prefix(120).description)
                    } else {
                        toolBriefs.append(name)
                    }
                default:
                    break
                }
            }
        }
        let text = textPieces.isEmpty ? nil : textPieces.joined(separator: "\n")
        let tool = toolBriefs.isEmpty ? nil : toolBriefs.joined(separator: " · ")
        return (text, tool)
    }
}
