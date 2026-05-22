import Foundation
import SwiftUI
import Combine

/// Internal JSONL watcher. No longer user-facing — exists so
/// HostedSessionManager can derive status for each hosted session by pairing it
/// to the JSONL Claude writes in ~/.claude/projects/.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastScanAt: Date?

    private let projectsRoot: URL
    private var watcher: ProjectsWatcher?
    private var refreshTimer: Timer?
    private var rescanInFlight = false
    nonisolated(unsafe) private static var parseCache: [String: (mtime: Date, session: Session)] = [:]
    nonisolated(unsafe) private static let cacheLock = NSLock()

    init(projectsRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsRoot = projectsRoot ?? home.appending(path: ".claude/projects")
        bootstrap()
    }

    private func bootstrap() {
        rescanAll()
        startWatching()
        // Ticker so "running" sessions transition to "idle" without a file write.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanAll() }
        }
    }

    private func startWatching() {
        let w = ProjectsWatcher(root: projectsRoot) { [weak self] urls in
            Task { @MainActor in self?.handleChanges(urls) }
        }
        w.start()
        self.watcher = w
    }

    func rescanAll() {
        guard !rescanInFlight else { return }
        rescanInFlight = true
        let root = projectsRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = Self.scan(root: root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessions = parsed
                self.lastScanAt = Date()
                self.rescanInFlight = false
            }
        }
    }

    private func handleChanges(_ urls: [URL]) {
        let current = sessions
        Task.detached(priority: .userInitiated) { [weak self] in
            var updated = current
            var byID = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($1.id, $0) })
            for url in urls {
                if let s = Self.parseWithCache(fileURL: url) {
                    if let i = byID[s.id] {
                        updated[i] = s
                    } else {
                        byID[s.id] = updated.count
                        updated.append(s)
                    }
                } else {
                    if let i = updated.firstIndex(where: { $0.fileURL == url }) {
                        updated.remove(at: i)
                    }
                }
            }
            let final = updated
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessions = final
                self.lastScanAt = Date()
            }
        }
    }

    /// Parses a single file, using the mtime cache to skip re-parsing unchanged files.
    nonisolated private static func parseWithCache(fileURL: URL) -> Session? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        cacheLock.lock()
        if let cached = parseCache[fileURL.path], cached.mtime == mtime {
            let s = cached.session
            cacheLock.unlock()
            return s
        }
        cacheLock.unlock()

        guard let session = SessionParser.parse(fileURL: fileURL) else { return nil }

        cacheLock.lock()
        parseCache[fileURL.path] = (mtime, session)
        cacheLock.unlock()
        return session
    }

    nonisolated private static func scan(root: URL) -> [Session] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        // Collect all jsonl URLs first so we can parse in parallel.
        var allFiles: [URL] = []
        var presentPaths = Set<String>()
        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                allFiles.append(f)
                presentPaths.insert(f.path)
            }
        }

        // Drop deleted files from the cache.
        cacheLock.lock()
        parseCache = parseCache.filter { presentPaths.contains($0.key) }
        cacheLock.unlock()

        // Parallel parse across cores. Locking around results array.
        var results = [Session?](repeating: nil, count: allFiles.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: allFiles.count) { i in
            let session = parseWithCache(fileURL: allFiles[i])
            resultsLock.lock()
            results[i] = session
            resultsLock.unlock()
        }
        return results.compactMap { $0 }
    }

}
