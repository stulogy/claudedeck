import Foundation
import SwiftUI

enum SessionStatus: String, Codable, CaseIterable {
    case running
    case waiting
    case idle
    case stale

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting on you"
        case .idle: return "Idle"
        case .stale: return "Stale"
        }
    }

    var color: Color {
        switch self {
        case .running: return .blue
        case .waiting: return .orange
        case .idle: return .secondary
        case .stale: return Color.secondary.opacity(0.5)
        }
    }

    var sortPriority: Int {
        switch self {
        case .waiting: return 0
        case .running: return 1
        case .idle: return 2
        case .stale: return 3
        }
    }

    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "hand.raised.fill"
        case .idle: return "moon.zzz"
        case .stale: return "clock.arrow.circlepath"
        }
    }
}

enum SessionEntrypoint: String {
    case cli
    case vscode
    case sdk
    case other

    init(raw: String?) {
        switch raw {
        case "cli": self = .cli
        case "claude-vscode": self = .vscode
        case "sdk-cli", "sdk": self = .sdk
        case .some: self = .other
        case .none: self = .cli
        }
    }

    var label: String {
        switch self {
        case .cli: return "Terminal"
        case .vscode: return "VS Code"
        case .sdk: return "SDK"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .cli: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .sdk: return "curlybraces"
        case .other: return "questionmark.circle"
        }
    }
}

struct Session: Identifiable, Hashable {
    let id: String              // sessionId (uuid)
    let fileURL: URL            // path to .jsonl
    let cwd: String             // working dir
    let title: String?          // aiTitle or first prompt snippet
    let lastPrompt: String?     // most recent user prompt text
    let lastActivity: Date      // file mtime / last entry timestamp
    let gitBranch: String?
    let version: String?
    let model: String?
    let status: SessionStatus
    let messageCount: Int
    let queuedCount: Int        // pending queued prompts
    let entrypoint: SessionEntrypoint

    /// Heuristic, no-LLM string describing what Claude is doing or asking.
    /// e.g. "Running Bash: npm test", "Editing src/auth.ts", "Asks: should we keep the legacy API?"
    let currentActivity: String?

    /// Stable identity of the last assistant message, used as a cache key for
    /// LLM-generated summaries so we re-summarize only when content changes.
    let lastAssistantFingerprint: String?

    /// Concatenated text of the most recent assistant turn, plus a brief tool_use
    /// description. Used as input to the optional LLM summarizer.
    let summarizerContext: String?

    var projectName: String {
        ProjectNaming.name(forCwd: cwd)
    }

    var prettyCwd: String {
        ProjectNaming.prettyCwd(cwd)
    }
}

enum ProjectNaming {
    static func name(forCwd cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home || cwd == "\(home)/" { return "Home" }
        let url = URL(fileURLWithPath: cwd)
        let last = url.lastPathComponent
        return last.isEmpty ? cwd : last
    }

    static func prettyCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
}
