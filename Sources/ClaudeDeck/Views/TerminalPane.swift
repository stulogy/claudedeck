import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView. Spawns `claude`
/// in a real pty bound to the session's cwd.
struct TerminalPane: NSViewRepresentable {
    let session: HostedSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        Self.applyAppearance(to: term)
        term.feed(text: "ClaudeDeck — starting claude in \(session.prettyCwd)\r\n")

        var env = Self.terminalEnvironment()
        env["CLAUDEDECK_HOSTED"] = "1"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // If we can find the claude binary directly, exec it. Otherwise fall
        // back to letting the login shell resolve it via PATH.
        let escapedCwd = session.cwd.replacingOccurrences(of: "'", with: "'\\''")
        let resumeArg: String
        if let rid = session.resumeSessionId, !rid.isEmpty {
            let escapedRid = rid.replacingOccurrences(of: "'", with: "'\\''")
            resumeArg = " --resume '\(escapedRid)'"
        } else {
            resumeArg = ""
        }
        let command: String
        if let claude = HostedSessionManager.resolveClaudePath() {
            command = "cd '\(escapedCwd)' && exec '\(claude)'\(resumeArg)"
        } else {
            term.feed(text: "claude binary not found in known locations; trying PATH…\r\n")
            command = "cd '\(escapedCwd)' && exec claude\(resumeArg)"
        }

        // `-i -l` so zsh sources both .zprofile AND .zshrc — many users keep
        // their PATH additions (e.g. `~/.local/bin`) in .zshrc, and a plain
        // `-l -c` non-interactive login shell skips that file.
        term.startProcess(
            executable: shell,
            args: ["-i", "-l", "-c", command],
            environment: envArray,
            execName: nil
        )

        // SwiftTerm exposes the child via term.process.shellPid. Hand it to the
        // session so the memory poller can read RSS.
        let pid = term.process.shellPid
        DispatchQueue.main.async {
            session.isAlive = true
            if pid > 0 { session.processPID = pid }
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Nothing — the pty + view manage themselves.
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.process.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: HostedSession
        init(session: HostedSession) { self.session = session }

        func sizeChanged(source: LocalProcessTerminalView,
                         newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // Intentionally ignored — `claude` sets the title to "✱ Claude Code"
            // for every session, which would clobber the project-derived tab name.
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                self.session.isAlive = false
                source.feed(text: "\r\n[claude exited, code \(exitCode ?? -1)]\r\n")
            }
        }
    }

    /// iTerm-style legibility: SF Mono 13pt, soft light-grey text on a dark
    /// charcoal background (not pure black, not pure white — easier on the
    /// eyes and matches the user's iTerm preset).
    static let terminalForeground = NSColor(red: 0.83, green: 0.84, blue: 0.86, alpha: 1.0) // ~#D4D6DB
    static let terminalBackground = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0) // ~#1F1F23

    private static func applyAppearance(to term: LocalProcessTerminalView) {
        let size: CGFloat = 13
        if let sfmono = NSFont(name: "SF Mono", size: size) {
            term.font = sfmono
        } else if let sfMonoFallback = NSFont(name: "SFMono-Regular", size: size) {
            term.font = sfMonoFallback
        } else {
            term.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        term.nativeForegroundColor = Self.terminalForeground
        term.nativeBackgroundColor = Self.terminalBackground
    }

    /// A minimal "good enough" terminal environment, inheriting from the app's
    /// environment and adding TERM + LANG so claude renders correctly.
    private static func terminalEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_ALL"] == nil { env["LC_ALL"] = "en_US.UTF-8" }
        env["COLORTERM"] = "truecolor"
        return env
    }
}
