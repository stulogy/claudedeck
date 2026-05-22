import Foundation
import SwiftUI

/// One-line rolling summary of what an agent has been up to. Different from
/// `Summarizer.summaries` (which only describes what the user has to do next);
/// this is a continuous "what is this agent working on" line.
struct AgentMemory: Codable, Equatable {
    let cwd: String                  // anchor (the agent's project)
    let claudeSessionId: String?     // matches the JSONL session id, used to rehydrate after restore
    let summary: String
    /// Fingerprint of the assistant turn this was built from. Used as a cache key.
    let fingerprint: String?
    let updatedAt: Date
}

/// A short paragraph describing what's going on across all agents in a project.
/// Updated less frequently than per-agent memory; it's the input to richer
/// insights ("agents X and Y are converging on the same file").
struct ProjectMemory: Codable, Equatable {
    let cwd: String
    let summary: String
    /// Per-agent summaries this paragraph was synthesized from. Used as a cache
    /// key so we don't re-summarize when nothing changed.
    let agentSummaryHashes: [String]
    let updatedAt: Date
}

/// A short observation surfaced via the lightbulb. Insights are computed from
/// memory + live state. The kind controls the icon + tint.
struct Insight: Identifiable, Equatable {
    enum Kind: String, Codable {
        case attention   // agents waiting on the user
        case ram         // process memory pressure
        case stuck       // agent looks stuck / repeating
        case idle        // long-idle but alive
        case collision   // multiple agents touching same area
        case info        // generic synthesized insight
    }

    let id: UUID
    let kind: Kind
    /// Headline — 1 short sentence the popover row uses as the primary label.
    let title: String
    /// Optional secondary line. Keep ≤140 chars.
    let detail: String?
    /// If set, clicking the insight focuses this project.
    let projectCwd: String?
    /// If set, clicking the insight focuses this specific agent.
    let agentId: UUID?
    let createdAt: Date

    init(kind: Kind,
         title: String,
         detail: String? = nil,
         projectCwd: String? = nil,
         agentId: UUID? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.detail = detail
        self.projectCwd = projectCwd
        self.agentId = agentId
        self.createdAt = Date()
    }
}

extension Insight.Kind {
    var symbol: String {
        switch self {
        case .attention: return "hand.raised.fill"
        case .ram:       return "memorychip.fill"
        case .stuck:     return "arrow.triangle.2.circlepath.circle.fill"
        case .idle:      return "moon.zzz.fill"
        case .collision: return "exclamationmark.triangle.fill"
        case .info:      return "lightbulb.fill"
        }
    }
    var tint: Color {
        switch self {
        case .attention: return .orange
        case .ram:       return .red
        case .stuck:     return .red
        case .idle:      return .secondary
        case .collision: return .yellow
        case .info:      return .accentColor
        }
    }
}

/// Identity key for an insight so we can dedupe across recomputes (same kind +
/// project + agent collapses to one row, latest copy wins).
extension Insight {
    var dedupeKey: String {
        "\(kind.rawValue)|\(projectCwd ?? "")|\(agentId?.uuidString ?? "")"
    }
}
