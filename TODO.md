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
- [x] Keyboard shortcuts (Cmd+T/W/1-9/D/N/O/E)
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
- [x] Watchdogs — semi-autonomous session monitors with triggers and auto-responses
- [x] Code editor/inspector (Cmd+E) with syntax highlighting, line numbers, file tabs, search
- [x] Voice transcription — on-device speech-to-text (Cmd+Shift+V)
- [x] Configurable toolkit — editable ~/.config/draftframe/toolkit.json
- [x] Worktree auto-cleanup on quit
- [x] Session persistence across restarts

## Remaining — Key Features
- [ ] **Projects with worktrees** — Organize worktrees under projects. Projects are the directory/repo that worktrees belong to. Allow opening new projects via file navigator (like app launch). Add an "Open Project" button in the sidebar. Each project gets its own set of worktrees and sessions. Support switching between projects.
- [ ] **PR inspector** — View GitHub PRs inline via `gh` CLI integration

## Remaining — Polish
- [ ] **App icon** — Custom icon for the dock
- [ ] **Font bundling** — Bundle IBM Plex Mono / Archivo instead of system mono
- [ ] **Preferences window** — Configure theme, font size, default model, keybindings
- [ ] **Scroll performance** — Ensure terminal stays responsive with long output
- [ ] **Session status tuning** — Verify thinking/generating/idle transitions across different Claude interactions
- [ ] **App bundle** — Package as proper .app with Info.plist for notifications/permissions
