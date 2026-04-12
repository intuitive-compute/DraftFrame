# DraftFrame

[![CI](https://github.com/intuitive-compute/draftframe/actions/workflows/ci.yml/badge.svg)](https://github.com/intuitive-compute/draftframe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A multi-session terminal for [Claude Code](https://claude.ai/claude-code). Run parallel Claude sessions with git worktree isolation, live status tracking, and a built-in toolkit.

## Download

Grab the latest DMG from [GitHub Releases](https://github.com/intuitive-compute/draftframe/releases/latest).

## Features

- **Multi-tab terminal** — SwiftTerm-based terminal with full ANSI color support
- **Parallel Claude sessions** — Run multiple Claude Code instances side by side
- **Git worktree isolation** — Each session gets its own worktree branch
- **Live session status** — Real-time detection of thinking/generating/idle/needs-attention states via PTY stream analysis
- **Session cards** — Visual dashboard showing each session's status, model, and cost
- **Cost tracking** — Reads Claude's JSONL session files for real token/cost data
- **Project management** — Persistent project list with expandable worktree trees
- **Changed files** — Git diff view showing modified/added/deleted files
- **Watchdogs** — Semi-autonomous monitors that auto-respond to session events
- **Code editor** — Built-in file inspector with syntax highlighting (Cmd+E)
- **Configurable toolkit** — One-click commands (test, build, lint) with output popovers
- **Voice transcription** — On-device speech-to-text via Apple Speech (Cmd+Shift+V)
- **Dashboard** — Full-screen session overview (Cmd+D)
- **Session persistence** — Restore sessions across app restarts
- **Keyboard shortcuts** — Cmd+T/W/1-9/D/N/O/E and more

## Requirements

- macOS 14.0+
- Swift 5.9+
- [Claude Code](https://claude.ai/claude-code) installed

## Build & Run

```bash
swift build
.build/debug/DraftFrame
```

## Packaging

See [DEVELOPMENT.md](DEVELOPMENT.md) for DMG packaging, signing, and notarization instructions.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New session |
| Cmd+W | Close session |
| Cmd+1-9 | Switch to session N |
| Cmd+D | Toggle dashboard |
| Cmd+E | Toggle code editor |
| Cmd+N | New session with worktree |
| Cmd+O | Open project |
| Cmd+Shift+V | Voice input |

## Architecture

Clean Swift Package Manager project using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation. No Xcode project needed — just `swift build`. See [DEVELOPMENT.md](DEVELOPMENT.md) for project structure and developer docs.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
