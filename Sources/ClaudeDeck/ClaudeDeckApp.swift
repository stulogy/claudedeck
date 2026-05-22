import SwiftUI

@main
struct ClaudeDeckApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var summarizer = Summarizer()
    @StateObject private var hosted = HostedSessionManager()
    @StateObject private var memory = MemoryService()

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
                }
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
