import Foundation

/// Static fixture data used when ClaudeDeck launches with `--demo`. Built to
/// look like a believable mid-day workspace: 5 projects, 8 agents, a mix of
/// statuses, realistic prompts + memory numbers, and canned terminal output
/// with ANSI styling that mirrors how Claude Code actually renders.
enum DemoFixtures {

    struct Agent {
        let cwd: String
        let title: String          // the LLM-generated tab title
        let status: SessionStatus
        let lastPrompt: String?
        let currentActivity: String?
        let memoryMB: Int          // shown in the sidebar % rollup
        let userMessageCount: Int
        let terminalText: String   // raw bytes (incl. ANSI escapes) fed to the pane
    }

    struct Project {
        let cwd: String
        let agents: [Agent]
    }

    // ANSI helpers used to build the canned terminal content.
    private static let bold = "\u{1B}[1m"
    private static let dim = "\u{1B}[2m"
    private static let reset = "\u{1B}[0m"
    private static let cyan = "\u{1B}[36m"
    private static let blue = "\u{1B}[34m"
    private static let green = "\u{1B}[32m"
    private static let yellow = "\u{1B}[33m"
    private static let red = "\u{1B}[31m"
    private static let mag = "\u{1B}[35m"
    private static let orange = "\u{1B}[38;5;208m"

    static let projects: [Project] = [
        // ───────────── stubuddy (3 agents) ─────────────
        Project(cwd: "~/Sites/stubuddy", agents: [
            Agent(
                cwd: "~/Sites/stubuddy",
                title: "iBeacon detection",
                status: .waiting,
                lastPrompt: "add iBeacon detection alongside GPS",
                currentActivity: "Choose: keep GPS as fallback or beacon-only mode?",
                memoryMB: 348,
                userMessageCount: 7,
                terminalText: makeTerminal(
                    cwd: "~/Sites/stubuddy",
                    blocks: [
                        .userPrompt("add iBeacon detection alongside GPS"),
                        .assistantText("I'll add iBeacon detection in \(bold)VenueManager.swift\(reset) alongside the GPS picker. Looking at the current implementation first."),
                        .toolUse("Read", "VenueManager.swift ↳ 562 lines"),
                        .assistantText("Got it. The hybrid picker will prefer beacon when in range, fall back to GPS. Adding the listener now."),
                        .toolUse("Edit", "VenueManager.swift ↳ \(green)+47 lines\(reset)"),
                        .toolUse("Bash", "xcodebuild -scheme StuBuddy -configuration Debug build ↳ \(green)BUILD SUCCEEDED\(reset)"),
                        .status("Brewed for 8s"),
                        .assistantText("Ready to test on device. Should I add a \(cyan)/testflight\(reset) gate before merging, or proceed straight to main?")
                    ]
                )
            ),
            Agent(
                cwd: "~/Sites/stubuddy",
                title: "Streaming + crossfade",
                status: .running,
                lastPrompt: "switch from AVAudioPlayer to two LoopingPlayers",
                currentActivity: "Running Bash: xcodebuild test",
                memoryMB: 412,
                userMessageCount: 12,
                terminalText: makeTerminal(
                    cwd: "~/Sites/stubuddy",
                    blocks: [
                        .userPrompt("switch from AVAudioPlayer to two LoopingPlayers with crossfade"),
                        .assistantText("Replacing the single AVAudioPlayer with a pair of AVQueuePlayer-backed LoopingPlayers — one active, one preloading the next clip. Crossfade happens by linearly ramping each player's volume over the swap window."),
                        .toolUse("Edit", "VenueView.swift ↳ \(green)+282 lines\(reset)"),
                        .toolUse("Edit", "SettingsSheet.swift ↳ \(green)+236 lines\(reset)"),
                        .assistantText("Tests next."),
                        .toolUse("Bash", "xcodebuild test -scheme StuBuddy"),
                        .status("Crunched for 14s")
                    ]
                )
            ),
            Agent(
                cwd: "~/Sites/stubuddy",
                title: "iOS submission notes",
                status: .idle,
                lastPrompt: "draft App Store reviewer notes for v1.4",
                currentActivity: nil,
                memoryMB: 198,
                userMessageCount: 5,
                terminalText: makeTerminal(
                    cwd: "~/Sites/stubuddy",
                    blocks: [
                        .userPrompt("draft App Store reviewer notes for v1.4"),
                        .assistantText("Drafted. Highlights: revised onboarding copy, beacon-aware venue picker, fixed the crossfade glitch on backgrounded audio. Demo credentials added below."),
                        .toolUse("Write", "App_Store_Submission/v1.4_review_notes.md"),
                        .status("Brewed for 4s"),
                        .assistantText("Awaiting your next prompt.")
                    ]
                )
            )
        ]),

        // ───────────── venue-audio backend (2 agents) ─────────────
        Project(cwd: "~/Sites/venue-audio", agents: [
            Agent(
                cwd: "~/Sites/venue-audio",
                title: "Live revision polling",
                status: .running,
                lastPrompt: "add /api/venue/public/session/:slug/rev polling every 15s",
                currentActivity: "Editing routes/venue.ts",
                memoryMB: 287,
                userMessageCount: 9,
                terminalText: makeTerminal(
                    cwd: "~/Sites/venue-audio",
                    blocks: [
                        .userPrompt("add /api/venue/public/session/:slug/rev polling every 15s so audience phones detect zone changes"),
                        .assistantText("New \(cyan)venue_sessions.rev\(reset) column plus a poll endpoint. Idempotent SQLite migration handles the column-add."),
                        .toolUse("Edit", "routes/venue.ts ↳ \(green)+62 lines\(reset)"),
                        .toolUse("Edit", "db/migrations/0019_venue_rev.sql"),
                        .toolUse("Bash", "bun run db:migrate ↳ migration applied"),
                        .status("Crunched for 6s")
                    ]
                )
            ),
            Agent(
                cwd: "~/Sites/venue-audio",
                title: "Stripe webhook bug",
                status: .waiting,
                lastPrompt: "investigate the 502 we're seeing on /webhooks/stripe",
                currentActivity: "Asks: should we retry idempotently or fail fast?",
                memoryMB: 156,
                userMessageCount: 6,
                terminalText: makeTerminal(
                    cwd: "~/Sites/venue-audio",
                    blocks: [
                        .userPrompt("investigate the 502 we're seeing on /webhooks/stripe"),
                        .assistantText("Found it. The handler awaits a downstream HubSpot call before responding — when HubSpot is slow (>10s), our nginx upstream times out and returns 502 to Stripe."),
                        .toolUse("Read", "routes/webhooks/stripe.ts"),
                        .toolUse("Grep", "STRIPE_TIMEOUT_MS"),
                        .assistantText("Two options:\n  \(bold)A.\(reset) Decouple — write the event to a queue and 200 immediately. HubSpot sync runs in a worker.\n  \(bold)B.\(reset) Fail fast — keep the inline call but cap it at 3s with a circuit breaker.\n\nA is more robust. B ships in an hour. Which?")
                    ]
                )
            )
        ]),

        // ───────────── marketing-site (1 agent) ─────────────
        Project(cwd: "~/Sites/marketing-site", agents: [
            Agent(
                cwd: "~/Sites/marketing-site",
                title: "Section consolidation",
                status: .running,
                lastPrompt: "audit the 50-section landing and recommend a 12-section structure",
                currentActivity: "Searching for duplicate testimonial blocks",
                memoryMB: 224,
                userMessageCount: 4,
                terminalText: makeTerminal(
                    cwd: "~/Sites/marketing-site",
                    blocks: [
                        .userPrompt("audit the 50-section landing page and recommend a 12-section structure"),
                        .assistantText("Counting and grouping by purpose:"),
                        .toolUse("Grep", "<section.*data-block= ↳ 51 matches"),
                        .toolUse("Read", "components/landing/*.tsx"),
                        .assistantText("Suggested condensed structure:"),
                        .raw("\n  \(mag)1.\(reset) Hero (was: 1, 4)\n  \(mag)2.\(reset) Social proof carousel (was: 8, 12, 19)\n  \(mag)3.\(reset) Three-pillar feature grid (was: 5, 6, 7, 22)\n  \(mag)4.\(reset) Waitlist signup — \(orange)new hero candidate\(reset) (was: 27)\n  \(mag)5.\(reset) FAQ (was: 41–45 deduped)\n  …7 more\n\n"),
                        .status("Crunched for 5s")
                    ]
                )
            )
        ]),

        // ───────────── onboarding-research (1 agent) ─────────────
        Project(cwd: "~/Sites/onboarding-research", agents: [
            Agent(
                cwd: "~/Sites/onboarding-research",
                title: "Interview synthesis",
                status: .idle,
                lastPrompt: "synthesize the 14 onboarding interviews into top 5 friction points",
                currentActivity: nil,
                memoryMB: 174,
                userMessageCount: 8,
                terminalText: makeTerminal(
                    cwd: "~/Sites/onboarding-research",
                    blocks: [
                        .userPrompt("synthesize the 14 onboarding interviews into top 5 friction points"),
                        .toolUse("Read", "interviews/*.md ↳ 14 files"),
                        .assistantText("Top friction points across the 14 transcripts:"),
                        .raw("\n  \(bold)1.\(reset) \(yellow)Email verification step is unexplained\(reset) — 11/14 paused here\n  \(bold)2.\(reset) \(yellow)Workspace name field — unclear if changeable\(reset) — 9/14\n  \(bold)3.\(reset) \(yellow)Pricing page interrupts flow\(reset) — 7/14\n  \(bold)4.\(reset) \(yellow)Mobile auth redirect drops session\(reset) — 5/14\n  \(bold)5.\(reset) \(yellow)Sample-data toggle is hidden\(reset) — 4/14\n\nWrote a deeper writeup to \(cyan)synthesis/v2.md\(reset).\n"),
                        .toolUse("Write", "synthesis/v2.md ↳ 4.1 KB"),
                        .status("Brewed for 11s"),
                        .assistantText("Awaiting your next prompt.")
                    ]
                )
            )
        ]),

        // ───────────── monolith refactor (1 agent) ─────────────
        Project(cwd: "~/Sites/api-monolith", agents: [
            Agent(
                cwd: "~/Sites/api-monolith",
                title: "Extract auth service",
                status: .running,
                lastPrompt: "extract the auth module into its own Go service",
                currentActivity: "Running Bash: go test ./internal/auth/...",
                memoryMB: 392,
                userMessageCount: 11,
                terminalText: makeTerminal(
                    cwd: "~/Sites/api-monolith",
                    blocks: [
                        .userPrompt("extract the auth module into its own Go service"),
                        .assistantText("Moving \(cyan)internal/auth\(reset) into a new \(cyan)services/auth\(reset) module with a thin gRPC contract. The monolith keeps a stub client for backward compat during the cutover."),
                        .toolUse("Bash", "mkdir -p services/auth/{cmd,internal,pkg}"),
                        .toolUse("Edit", "services/auth/cmd/main.go ↳ \(green)+128 lines\(reset)"),
                        .toolUse("Edit", "internal/auth/client.go ↳ \(red)-512\(reset) \(green)+34\(reset)"),
                        .toolUse("Bash", "go test ./internal/auth/..."),
                        .status("Crunched for 22s")
                    ]
                )
            )
        ])
    ]

    // MARK: - Composition helpers

    private enum Block {
        case userPrompt(String)
        case assistantText(String)
        case toolUse(String, String)   // tool name + brief
        case status(String)            // dim italic line ("Crunched for 5s")
        case raw(String)               // pre-formatted (already-escaped) text
    }

    private static func makeTerminal(cwd: String, blocks: [Block]) -> String {
        var s = ""
        // Claude Code splash header.
        s += "\r\n"
        s += "  \(bold)Claude Code\(reset) \(dim)v2.1.144\(reset)\r\n"
        s += "  \(dim)Opus 4.7 (1M context) · Claude Max\(reset)\r\n"
        s += "  \(dim)\(cwd)\(reset)\r\n\r\n"
        for block in blocks {
            switch block {
            case .userPrompt(let text):
                s += "\(bold)\u{203A}\(reset) \(text)\r\n\r\n"
            case .assistantText(let text):
                s += "\(orange)●\(reset) \(text)\r\n\r\n"
            case .toolUse(let name, let brief):
                s += "  \(cyan)\(name)\(reset)(\(brief))\r\n\r\n"
            case .status(let text):
                s += "\(dim)\u{2733} \(text)\(reset)\r\n\r\n"
            case .raw(let text):
                s += text
            }
        }
        // Trailing prompt indicator.
        s += "\(bold)\u{203A}\(reset) "
        // Normalize \n → \r\n for the terminal.
        return s.replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "\r\r\n", with: "\r\n")
    }
}
