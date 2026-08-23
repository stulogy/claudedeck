import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView. Spawns `claude`
/// in a real pty bound to the session's cwd.
struct TerminalPane: NSViewRepresentable {
    let session: HostedSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        NSLog("[ClaudeDeck.lifecycle] TerminalPane.makeNSView sid=%@ cwd=%@",
              session.id.uuidString, session.cwd)
        Self.installShiftReturnMonitorIfNeeded()
        let term = LocalProcessTerminalView(frame: .zero)
        Self.terminalsBySessionId[session.id] = WeakTerminal(term)
        term.processDelegate = context.coordinator
        // Demo mode short-circuit: skip the pty, just feed the canned text so
        // the screenshot shows realistic Claude Code output without burning
        // tokens or actually spawning claude.
        if let demoText = session.demoTerminalText {
            Self.applyAppearance(to: term)
            let interceptor = TerminalLinkInterceptor()
            interceptor.pty = term
            context.coordinator.linkInterceptor = interceptor
            term.terminalDelegate = interceptor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                term.feed(text: demoText)
            }
            return term
        }
        // Replace SwiftTerm's default terminalDelegate (which is LocalProcess-
        // TerminalView itself) with our interceptor. The interceptor forwards
        // every TerminalViewDelegate method back to the real terminal — except
        // `requestOpenLink`, which we re-route through `.claudeDeckOpenPath`
        // so it can be resolved against the agent's cwd and either preview as
        // markdown or hand off to the user's default app.
        let interceptor = TerminalLinkInterceptor()
        interceptor.pty = term
        context.coordinator.linkInterceptor = interceptor
        term.terminalDelegate = interceptor
        Self.applyAppearance(to: term)
        // No banner — claude prints its own startup line. Our old
        // "ClaudeDeck — starting claude in …" left a misleading "still
        // starting" string sitting permanently in the scrollback.

        var env = Self.terminalEnvironment()
        env["CLAUDEDECK_HOSTED"] = "1"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // If we can find the claude binary directly, exec it. Otherwise fall
        // back to letting the login shell resolve it via PATH.
        let escapedCwd = session.cwd.replacingOccurrences(of: "'", with: "'\\''")
        let resumeArg: String
        if session.useContinueOnSpawn {
            // `--continue` reliably loads the most-recent conversation in the
            // cwd. Preferred over `--resume <id>` for restoration because some
            // claude versions silently fork a fresh session on --resume.
            resumeArg = " --continue"
        } else if let rid = session.resumeSessionId, !rid.isEmpty {
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
        NSLog("[ClaudeDeck.lifecycle] TerminalPane.dismantleNSView sid=%@ cwd=%@ — pty will be terminated",
              coordinator.session.id.uuidString, coordinator.session.cwd)
        terminalsBySessionId.removeValue(forKey: coordinator.session.id)
        nsView.process.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: HostedSession
        /// Strong reference — `term.terminalDelegate` is weak, so somebody has
        /// to hold on to the interceptor or it'd get deallocated immediately.
        var linkInterceptor: TerminalLinkInterceptor?
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

    /// Stand-in for the LocalProcessTerminalView-as-its-own-delegate setup
    /// SwiftTerm wires up in `setup()`. We forward each required method to the
    /// real terminal's public implementations — except `requestOpenLink`,
    /// which we redirect into ClaudeDeck so we can resolve relative paths and
    /// preview markdown inline instead of throwing a `-50` dialog at the user.
    final class TerminalLinkInterceptor: NSObject, TerminalViewDelegate {
        weak var pty: LocalProcessTerminalView?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty?.send(source: source, data: data)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            pty?.setTerminalTitle(source: source, title: title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            pty?.hostCurrentDirectoryUpdate(source: source, directory: directory)
        }
        func scrolled(source: TerminalView, position: Double) {
            pty?.scrolled(source: source, position: position)
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            pty?.rangeChanged(source: source, startY: startY, endY: endY)
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            pty?.clipboardCopy(source: source, content: content)
        }
        // bell / iTermContent / requestOpenLink fall through, but the protocol
        // extension's defaults are fine for the first two. We override
        // requestOpenLink explicitly.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            NotificationCenter.default.post(
                name: .claudeDeckOpenPath,
                object: nil,
                userInfo: ["raw": link]
            )
        }
    }

    /// SF Mono 13pt, neutral grey background that matches the right-pane
    /// ambient (no blue tint — earlier value had a slight cool cast that read
    /// as "off" against the macOS dark-mode window chrome).
    static let terminalForeground = NSColor(white: 0.86, alpha: 1.0) // ~#DBDBDB
    static let terminalBackground = NSColor(white: 0.115, alpha: 1.0) // ~#1D1D1D — matches .underPageBackgroundColor in dark mode

    private static func applyAppearance(to term: LocalProcessTerminalView) {
        let size: CGFloat = 13
        registerBundledFontIfNeeded()
        term.font = NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        term.nativeForegroundColor = Self.terminalForeground
        term.nativeBackgroundColor = Self.terminalBackground
        term.terminal.options.scrollback = 10_000
        term.linkReporting = .implicit
        term.linkHighlightMode = .hoverWithModifier
        // Disable mouse reporting so user clicks always do native text
        // selection. With it on, claude (or any TUI tool that toggles xterm
        // mouse mode) would have ClaudeDeck forward clicks to the PTY instead,
        // which silently breaks double-click word select + drag-to-select.
        term.allowMouseReporting = false
    }

    // MARK: - Focus routing

    /// Weak wrapper so the static dictionary doesn't keep dead terminals alive.
    final class WeakTerminal {
        weak var view: LocalProcessTerminalView?
        init(_ view: LocalProcessTerminalView) { self.view = view }
    }

    nonisolated(unsafe) static var terminalsBySessionId: [UUID: WeakTerminal] = [:]

    /// Make the terminal for `sessionId` first responder so the user can start
    /// typing immediately after switching tabs/projects, returning to the
    /// window, or refocusing the app. Async-dispatched so SwiftUI's pending
    /// view updates settle first (otherwise the responder swap can race the
    /// activeSessionId change and bounce back).
    @MainActor
    static func focusTerminal(sessionId: UUID) {
        guard let term = terminalsBySessionId[sessionId]?.view else { return }
        DispatchQueue.main.async {
            guard let window = term.window else { return }
            if window.firstResponder !== term {
                window.makeFirstResponder(term)
            }
        }
    }

    /// Register the bundled JetBrainsMono-Regular.ttf at app launch. xcodegen
    /// flattens our Resources/Fonts directory into the bundle's Resources/
    /// root, so the macOS auto-registration via Info.plist's
    /// `ATSApplicationFontsPath` doesn't find it. Registering manually here is
    /// path-independent and idempotent.
    nonisolated(unsafe) private static var fontRegistered = false
    private static func registerBundledFontIfNeeded() {
        guard !fontRegistered else { return }
        fontRegistered = true
        guard let url = Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf") else {
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
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

    // MARK: - Shift+Return interception

    /// SwiftTerm sends `\r` for both Return and Shift+Return, so claude code
    /// can't tell them apart — pressing Shift+Return submits the prompt
    /// instead of inserting a newline. We install one local NSEvent monitor at
    /// app launch that catches Shift+Return when any LocalProcessTerminalView
    /// has focus and writes a literal LF (`\n`) to its PTY instead.
    nonisolated(unsafe) private static var shiftReturnMonitorInstalled = false

    @MainActor
    private static func installShiftReturnMonitorIfNeeded() {
        guard !shiftReturnMonitorInstalled else { return }
        shiftReturnMonitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let returnKey: UInt16 = 36
            guard event.keyCode == returnKey,
                  event.modifierFlags.contains(.shift),
                  let term = focusedTerminal() else {
                return event
            }
            term.send(txt: "\n")
            return nil
        }
    }

    /// Walk the responder chain up from the key window's first responder until
    /// we find a LocalProcessTerminalView. Needed because SwiftTerm's actual
    /// keyboard-handling responder may be a subview.
    @MainActor
    private static func focusedTerminal() -> LocalProcessTerminalView? {
        var r: NSResponder? = NSApp.keyWindow?.firstResponder
        while let current = r {
            if let term = current as? LocalProcessTerminalView { return term }
            r = current.nextResponder
        }
        return nil
    }

}
