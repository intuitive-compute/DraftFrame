# Draftframe TODO

## Done ✅
- [x] Real terminal (SwiftTerm) with ANSI colors
- [x] 3-pane dark UI (sidebar, terminal, session cards)
- [x] Multi-tab terminal sessions (Cmd+T, click to switch)
- [x] Session cards with pixel avatars, status, model, cost
- [x] Claude auto-launch on new tab
- [x] Git worktree creation/removal with context menus
- [x] Open session from worktree click
- [x] Real-time Claude status detection via PTY stream interception
- [x] Keyboard shortcuts (Cmd+T/W/1-9/D/N/O)
- [x] Toolkit buttons with output popovers
- [x] Status bar with branch/tokens/cost
- [x] Dashboard overlay (Cmd+D) with terminate/restart buttons
- [x] JSONL cost/token tracking from ~/.claude/projects/
- [x] Tab close buttons (×)
- [x] Double-click to rename sessions
- [x] macOS menu bar (File/View/Session/Help)
- [x] macOS notifications for background sessions
- [x] Draggable sidebar dividers (NSSplitView)
- [x] Directory picker on launch
- [x] Titlebar offset fix for traffic lights

## Remaining — Key Scape Features
- [ ] **Watchdogs** — Semi-autonomous session monitors that watch Claude sessions and auto-respond based on triggers (session needs input, error detected, periodic check)
- [ ] **Code editor/inspector** — Toggleable pane (Cmd+E) with syntax highlighting, line numbers, file tabs, search
- [ ] **PR inspector** — View GitHub PRs inline via `gh` CLI integration

## Remaining — Nice to Have
- [ ] **Voice transcription** — On-device speech-to-text via Apple Speech framework, push-to-talk (Cmd+Shift+V), transcribed text sent to active session
- [ ] **Configurable toolkit** — Load commands from `~/.config/draftframe/toolkit.json` instead of hardcoded defaults
- [ ] **Worktree auto-cleanup** — Clean up orphaned worktrees on app quit
- [ ] **Session persistence** — Remember open sessions across app restarts

## Remaining — Polish
- [ ] **App icon** — Custom icon for the dock
- [ ] **Font bundling** — Bundle IBM Plex Mono / Archivo instead of system mono
- [ ] **Preferences window** — Configure theme, font size, default model, keybindings
- [ ] **Scroll performance** — Ensure terminal stays responsive with long output
- [ ] **Session status tuning** — Verify thinking/generating/idle transitions across different Claude interactions
