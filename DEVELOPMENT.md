# Development Guide

## Prerequisites

- macOS 14.0+
- Swift 5.9+ (included with Xcode 15+)
- [Claude Code](https://claude.ai/claude-code) installed (for runtime testing)

## Quick Start

```bash
swift build
.build/debug/DraftFrame
```

## Project Structure

```
Package.swift              # SPM manifest
Sources/
  DraftFrame/              # Executable target (entry point)
    main.swift
    AppIcon.png
  DraftFrameKit/           # Library target (all app logic)
    DFAppDelegate.swift    # App lifecycle, menu bar, window setup
    DFWindowController.swift # Main window management
    DFTerminalPane.swift   # SwiftTerm terminal wrapper
    ClaudeTerminalView.swift # Terminal view subclass
    DFSidebar.swift        # Project/session sidebar
    DFSessionBar.swift     # Tab bar for sessions
    DFStatusBar.swift      # Bottom status bar
    DFDashboard.swift      # Full-screen session overview
    DFCodeEditor.swift     # Built-in file viewer
    SessionManager.swift   # Session lifecycle
    SessionPersistence.swift # Save/restore sessions
    SessionJSONLWatcher.swift # Parse Claude JSONL for cost/model
    PTYStreamAnalyzer.swift # Detect session state from PTY output
    ProjectManager.swift   # Project list persistence
    WorktreeManager.swift  # Git worktree operations
    WatchdogManager.swift  # Semi-autonomous session monitors
    ToolkitManager.swift   # Configurable command buttons
    NotificationManager.swift # macOS notifications
    VoiceManager.swift     # On-device speech-to-text
    Shortcuts.swift        # Keyboard shortcut definitions
    Theme.swift            # Colors and styling
Tests/
  DraftFrameTests/         # Unit tests
scripts/
  package.sh               # Build + sign + DMG packaging
```

## Architecture

DraftFrame is a pure Swift Package Manager project — no `.xcodeproj` needed.

- **DraftFrameKit** — a library target containing all application logic. This separation enables unit testing without launching the full app.
- **DraftFrame** — a thin executable target that imports `DraftFrameKit` and starts the app.

The app uses AppKit directly (no SwiftUI) and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation.

## Testing

```bash
swift test
```

Tests live in `Tests/DraftFrameTests/` and link against `DraftFrameKit`.

## Packaging

See the [README](README.md#package-as-a-signed-dmg) for DMG build instructions.

## Key Concepts

- **Sessions** — each tab is a terminal running a Claude Code process. `SessionManager` handles lifecycle; `SessionPersistence` saves/restores across app restarts.
- **PTY stream analysis** — `PTYStreamAnalyzer` watches raw terminal output to detect whether Claude is thinking, generating, idle, or needs attention.
- **JSONL watching** — `SessionJSONLWatcher` reads Claude's `~/.claude/projects/*/session.jsonl` files to extract token counts, costs, and model info.
- **Worktrees** — `WorktreeManager` creates isolated git worktrees so parallel sessions don't conflict.
- **Watchdogs** — `WatchdogManager` monitors sessions and can auto-respond to events (e.g., send input when Claude asks for confirmation).
