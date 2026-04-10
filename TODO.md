# Draftframe TODO

## Critical — Core Functionality
- [ ] **Cost/token tracking from JSONL** — Read `~/.claude/projects/` session files to get real cost, token counts, and model info instead of showing $0.00
- [ ] **Session status accuracy** — Verify thinking/generating/idle transitions work reliably across different Claude interactions. May need tuning.
- [ ] **Toolkit output feedback** — Show command output in a popover or bottom panel when clicking Run Tests/Build/Lint
- [ ] **Dashboard action buttons** — Wire Terminate/Restart buttons in the Cmd+D dashboard view

## Important — Key Scape Features
- [ ] **Watchdogs** — Semi-autonomous session monitors that watch Claude sessions and auto-respond based on triggers (session needs input, error detected, periodic check)
- [ ] **Code editor/inspector** — Right-side pane (Cmd+E) with syntax highlighting, line numbers, file tabs, search. Use tree-sitter or regex-based highlighting.
- [ ] **PR inspector** — View GitHub PRs inline via `gh` CLI integration

## Nice to Have
- [ ] **Voice transcription** — On-device speech-to-text via Apple Speech framework, push-to-talk (Cmd+Shift+V), transcribed text sent to active session
- [ ] **Configurable toolkit** — Load commands from `~/.config/draftframe/toolkit.json` instead of hardcoded defaults
- [ ] **Worktree auto-cleanup** — Clean up orphaned worktrees on app quit
- [ ] **Session persistence** — Remember open sessions across app restarts
- [ ] **Notification support** — macOS notifications when a session needs attention

## Polish
- [ ] **App icon** — Custom icon for the dock
- [ ] **Menu bar** — Proper macOS menu bar with File/Edit/View/Session menus
- [ ] **Font bundling** — Bundle IBM Plex Mono / Archivo instead of system mono
- [ ] **Preferences window** — Configure theme, font size, default model, keybindings
- [ ] **Sidebar resize** — Draggable dividers between sidebar/terminal/session bar
- [ ] **Tab close buttons** — X button on each tab, not just Cmd+W
- [ ] **Session rename** — Double-click session card or tab to rename
- [ ] **Scroll performance** — Ensure terminal stays responsive with long output
