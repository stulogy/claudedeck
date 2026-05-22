# ClaudeDeck

A native macOS dashboard for [Claude Code](https://claude.com/claude-code) sessions.

ClaudeDeck surfaces every Claude Code agent you have running, grouped by project, so you can see at a glance which need your attention, which are working, and which are eating memory — without tab-switching across Terminal, iTerm, or VS Code instances.

## Features

- **Project-level view** — agents in the same working directory collapse into one row, with counts of how many are waiting on you, running, or idle.
- **Memory awareness** — total process RAM per project as a percentage of system memory, color-coded.
- **Resizable sidebar** — drag to a narrow icon-rail when you want more terminal space.
- **Session restoration** — on relaunch, ClaudeDeck offers to resume each agent where it left off via `claude --resume <session-id>`.
- **Optional Claude-powered insights** — with your Anthropic API key, ClaudeDeck can produce one-line summaries of what each waiting agent is asking, draft replies you can paste back into the terminal, and (in progress) cross-project insights surfaced via a lightbulb popover.
- **Lives in the menu bar** — compact dropdown that shows status counts and lets you jump to any session.

## Requirements

- macOS 14.0 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Claude Code](https://claude.com/claude-code) installed and discoverable on `PATH` (or in one of the well-known locations ClaudeDeck checks)

## Build

```sh
git clone git@github.com:stulogy/claudedeck.git
cd claudedeck
xcodegen generate
open ClaudeDeck.xcodeproj
```

Or build from the command line:

```sh
xcodebuild -project ClaudeDeck.xcodeproj -scheme ClaudeDeck -configuration Debug build
```

The `.xcodeproj` is regenerated from `project.yml`, so it's not committed — run `xcodegen generate` after pulling.

## How it works

ClaudeDeck reads the JSONL transcripts Claude Code writes to `~/.claude/projects/<escaped-cwd>/<session-uuid>.jsonl` directly. There's no UI scraping or accessibility hooks — status is inferred from the transcript:

| Inferred status | Signal |
|---|---|
| **Waiting on you** | Last entry is an assistant turn with `stop_reason: end_turn` after at least one user prompt |
| **Running** | Last assistant turn has `stop_reason: tool_use` and no matching `tool_result` yet; or a user turn is being processed |
| **Idle** | File untouched for more than 5 minutes |
| **Stale** | File untouched for more than 24 hours |

Per-process memory is read via Darwin's `proc_pidinfo` syscall — no entitlements required.

## Privacy

Your Anthropic API key (if you enable summaries) is stored in macOS Keychain, never written to disk in plain text. All LLM calls are opt-in via Settings and go directly from your machine to `api.anthropic.com`.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal view.
- Claude Code, obviously.
