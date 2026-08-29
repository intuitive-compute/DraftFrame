---
name: qa
description: QA DraftFrame end to end by launching the real app with its automation bridge and driving it with the dfqa CLI - create sessions, send keystrokes, read terminal output, take pixel-perfect screenshots, and invoke menus. Use after implementing a feature to verify it works in the running app, or when asked to QA, smoke-test, or reproduce a UI bug.
---

# DraftFrame QA loop

DraftFrame has a built-in QA automation bridge (`QABridge.swift`). When the app
is launched with `DRAFTFRAME_QA_SOCKET=<path>`, it serves JSON commands on a
Unix socket; the `dfqa` executable target is the client. The bridge is off in
normal launches, and QA mode never writes to the user's persisted state
(`~/.config/draftframe/sessions.json`, `projects.json`).

## Workflow

1. **Build both targets**: `swift build` (builds `DraftFrame` and `dfqa`).
2. **Launch the app under QA** (a real window appears on the user's screen):

   ```bash
   export DRAFTFRAME_QA_SOCKET=/tmp/draftframe-qa.sock
   nohup .build/debug/DraftFrame > /tmp/draftframe-qa.log 2>&1 &
   sleep 3
   .build/debug/dfqa ping
   ```

3. **Drive it** with `dfqa` (run `dfqa help` for full usage):
   - `dfqa state` / `dfqa sessions` — app and session state (session state,
     model, cost, dashboard/quick-terminal visibility, window frame).
   - `dfqa open-project --path DIR` — open a project (starts a session in it).
   - `dfqa new-session [--name N] [--worktree PATH]`, `dfqa select --index N`,
     `dfqa close-session --index N`.
   - `dfqa send --text STR [--enter] [--index N]` — keystrokes to a session's
     PTY. Control characters work via `raw` with JSON escapes (e.g.
     `{"cmd":"send","text":""}` for Escape).
   - `dfqa read [--lines N] [--index N]` — the visible terminal screen as text.
   - `dfqa screenshot PATH [--window main|quick|key]` — pixel-perfect window
     capture (no screen-recording permission needed). Read the PNG to verify
     visually.
   - `dfqa menu "View>Toggle Dashboard"` — invoke any menu item by title path
     (fires async, so items that open modals won't hang the bridge).
4. **Always finish with** `dfqa quit` (QA mode skips the worktree-cleanup
   modal and persistence writes). If the app hangs, `kill -9` it — never let a
   wedged QA instance linger.

## Cautions

- **New sessions launch the real agent CLI** (Claude Code or Codex). Use a
  scratch project directory (e.g. under the session scratchpad, `git init` +
  one commit) so QA sessions don't touch real repos, and don't send prompts to
  the spawned agent unless the test requires it — prompts cost real tokens.
- The user's production DraftFrame may be running at the same time; that's
  fine (different process, QA writes no shared state), but never kill or drive
  their instance — only the one you launched.
- First run in a fresh scratch dir: Claude Code shows a folder-trust prompt;
  answer it with `dfqa send --text "1"`.
- `dfqa read` reflects the visible screen only; take screenshots for layout
  and chrome, `read` for terminal text.
