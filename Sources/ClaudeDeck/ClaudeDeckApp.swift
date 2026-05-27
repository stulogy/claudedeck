import SwiftUI

@main
struct ClaudeDeckApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var summarizer = Summarizer()
    @StateObject private var hosted = HostedSessionManager()
    @StateObject private var memory = MemoryService()
    @StateObject private var wakelock = Wakelock()

    var body: some Scene {
        WindowGroup("ClaudeDeck") {
            WorkspaceView()
                .environmentObject(store)
                .environmentObject(summarizer)
                .environmentObject(hosted)
                .environmentObject(memory)
                .onAppear {
                    hosted.attach(sessionStore: store, summarizer: summarizer)
                    memory.attach(hosted: hosted, summarizer: summarizer)
                    wakelock.begin()
                }
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    NotificationCenter.default.post(name: .claudeDeckNewSession, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("New Tab") {
                    NotificationCenter.default.post(name: .claudeDeckNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .claudeDeckCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Next Project") {
                    NotificationCenter.default.post(name: .claudeDeckCycleProject, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)
                Button("Next Tab in Project") {
                    NotificationCenter.default.post(name: .claudeDeckCycleTab, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsWindow()
                .environmentObject(summarizer)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(hosted)
                .environmentObject(summarizer)
                .environmentObject(memory)
        } label: {
            MenuBarLabel(hosted: hosted)
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    /// File → New Session… (⌘⇧S). Sidebar listens and opens the sheet.
    static let claudeDeckNewSession = Notification.Name("ClaudeDeck.newSession")
    /// File → New Tab (⌘T). Workspace listens and spawns another agent in the
    /// currently active project. Quietly does nothing if no project is active.
    static let claudeDeckNewTab = Notification.Name("ClaudeDeck.newTab")
    /// File → Close Tab (⌘W). Workspace listens, surfaces a confirmation
    /// before terminating the active agent.
    static let claudeDeckCloseTab = Notification.Name("ClaudeDeck.closeTab")
    /// Navigate → Next Project (⌘`). Cycles the active project in sidebar order.
    static let claudeDeckCycleProject = Notification.Name("ClaudeDeck.cycleProject")
    /// Navigate → Next Tab in Project (⌘⇧`). Cycles the active agent within
    /// the current project's tab strip.
    static let claudeDeckCycleTab = Notification.Name("ClaudeDeck.cycleTab")
    /// Posted by TerminalPane when the user ⌘-clicks a file-path-looking
    /// token. WorkspaceView resolves it against the active agent's cwd and
    /// either shows the markdown preview sheet (`.md`) or hands it off to
    /// NSWorkspace.
    static let claudeDeckOpenPath = Notification.Name("ClaudeDeck.openPath")
    /// Posted by ProjectActionsMenu when the user picks "View Transcripts".
    /// The notification's `object` carries the `Project` whose JSONL
    /// transcripts should be loaded into the viewer sheet.
    static let claudeDeckOpenTranscripts = Notification.Name("ClaudeDeck.openTranscripts")
}

/// Keeps the Mac from going to sleep while ClaudeDeck is running so the
/// claude agents can keep working in the background. Uses
/// `ProcessInfo.beginActivity` rather than the raw IOKit assertion or
/// shelling out to `caffeinate` — it's the modern API and integrates with
/// macOS's power-management heuristics. `.idleSystemSleepDisabled` blocks
/// system sleep; we deliberately don't request `.idleDisplaySleepDisabled`,
/// so the screen can still dim when you walk away.
@MainActor
final class Wakelock: ObservableObject {
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "ClaudeDeck has live Claude Code agents"
        )
    }

    func end() {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        // ProcessInfo holds the token weakly through endActivity; releasing
        // here keeps the assertion lifecycle tied to the app's.
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var hosted: HostedSessionManager
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: waitingCount > 0 ? "hand.raised.fill" : "rectangle.stack.fill")
            if waitingCount > 0 {
                Text("\(waitingCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
    }
    private var waitingCount: Int {
        hosted.sessions.filter { $0.status == .waiting }.count
    }
}
