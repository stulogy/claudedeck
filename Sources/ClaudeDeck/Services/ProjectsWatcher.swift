import Foundation
import CoreServices

/// Recursively watches a directory using FSEvents and fires a callback whenever
/// any file inside changes. Coalesces bursts via a debounce timer.
final class ProjectsWatcher {
    private let root: URL
    private let onChange: ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "co.ailogy.claudedeck.fsevents")
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    private let lock = NSLock()

    init(root: URL, onChange: @escaping ([URL]) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        stop()
        let paths = [root.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            watcher.handle(paths: Array(paths.prefix(numEvents)))
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }

    private func handle(paths: [String]) {
        lock.lock()
        for p in paths where p.hasSuffix(".jsonl") {
            pendingPaths.insert(p)
        }
        lock.unlock()

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let urls = self.pendingPaths.map { URL(fileURLWithPath: $0) }
            self.pendingPaths.removeAll()
            self.lock.unlock()
            if !urls.isEmpty {
                self.onChange(urls)
            }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
