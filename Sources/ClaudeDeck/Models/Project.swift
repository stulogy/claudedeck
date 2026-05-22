import Foundation
import SwiftUI

/// A group of HostedSessions that share a working directory. Computed live from
/// HostedSessionManager.sessions; not stored. Identity is the cwd.
@MainActor
struct Project: Identifiable, Hashable {
    let cwd: String
    let sessions: [HostedSession]

    var id: String { cwd }

    var name: String { ProjectNaming.name(forCwd: cwd) }
    var prettyCwd: String { ProjectNaming.prettyCwd(cwd) }

    var attentionCount: Int { sessions.filter { $0.status == .waiting }.count }
    var workingCount: Int   { sessions.filter { $0.status == .running }.count }
    var idleCount: Int      { sessions.filter { $0.status == .idle || $0.status == .stale }.count }

    /// Sum of resident bytes across all sessions in this project.
    var totalMemoryBytes: UInt64 {
        sessions.reduce(UInt64(0)) { acc, s in acc &+ (s.memoryRSS ?? 0) }
    }

    var prettyTotalMemory: String? {
        let bytes = totalMemoryBytes
        guard bytes > 0 else { return nil }
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1 { return "<1 MB" }
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// Project memory as a percent of total system RAM.
    var memoryPercentOfRAM: Double {
        let total = Double(SystemMemory.physicalBytes)
        guard total > 0 else { return 0 }
        return Double(totalMemoryBytes) / total * 100.0
    }

    var memoryTier: MemoryTier {
        let p = memoryPercentOfRAM
        if p >= 50 { return .red }
        if p >= 25 { return .amber }
        return .green
    }

    /// Highest-priority session for this project (waiting > running > idle > stale).
    /// Used when activating a project to pick which agent the right pane focuses on.
    var topSession: HostedSession? {
        sessions.sorted { $0.status.sortPriority < $1.status.sortPriority }.first
    }

    /// Agents within this project, severity-ordered (attention first).
    var orderedSessions: [HostedSession] {
        sessions.sorted { a, b in
            if a.status.sortPriority != b.status.sortPriority {
                return a.status.sortPriority < b.status.sortPriority
            }
            return a.createdAt < b.createdAt
        }
    }

    /// Most recent activity across all sessions in the project.
    var lastActivity: Date? {
        sessions.compactMap { $0.lastActivity ?? $0.createdAt }.max()
    }

    static func == (lhs: Project, rhs: Project) -> Bool { lhs.cwd == rhs.cwd }
    func hash(into hasher: inout Hasher) { hasher.combine(cwd) }
}

enum MemoryTier {
    case green, amber, red

    var color: Color {
        switch self {
        case .green: return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }
}
