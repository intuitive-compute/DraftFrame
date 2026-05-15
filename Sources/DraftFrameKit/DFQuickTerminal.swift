import AppKit
import SwiftTerm

/// Floating quick-terminal window. Toggled with Cmd+` (backtick). Each
/// session tab owns its own shell — switching tabs swaps which terminal
/// view is mounted in the single floating window. Shells persist across
/// show/hide and across session switches, so scrollback and in-flight
/// commands survive a toggle.
final class DFQuickTerminal {
  static let shared = DFQuickTerminal()

  private var window: NSWindow?
  private var container: NSView?
  private var terminals: [UUID: ClaudeTerminalView] = [:]
  private var currentlyInstalledSessionID: UUID?

  /// Container inset matching the transparent titlebar so content doesn't
  /// render behind the traffic lights.
  private static let titlebarInset: CGFloat = 28

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(activeSessionDidChange),
      name: .activeSessionDidChange,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sessionsDidChange),
      name: .sessionsDidChange,
      object: nil)
  }

  /// Show the quick terminal if hidden, hide it if currently visible and key.
  /// If visible but not key (user clicked the main window), re-focus it
  /// instead of hiding — avoids requiring a double Cmd+` to get it back.
  func toggle() {
    if let win = window, win.isVisible {
      if win.isKeyWindow {
        win.orderOut(nil)
      } else {
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let id = currentlyInstalledSessionID, let tv = terminals[id] {
          win.makeFirstResponder(tv)
        }
      }
    } else {
      show()
    }
  }

  func show() {
    if window == nil {
      buildWindow()
    }
    guard let win = window else { return }
    guard let active = SessionManager.shared.activeSession else {
      // No session to attach to — quick terminal is session-scoped.
      return
    }
    let tv = terminal(for: active)
    install(tv, for: active)
    positionAtTop(of: win)
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    win.makeFirstResponder(tv)
  }

  func hide() {
    window?.orderOut(nil)
  }

  // MARK: - Window setup

  private func buildWindow() {
    let contentRect = NSRect(x: 0, y: 0, width: 900, height: 340)
    let win = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    win.title = "Quick Terminal"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = Theme.bg
    win.isMovableByWindowBackground = false
    win.hidesOnDeactivate = true
    win.level = .normal
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    win.isReleasedWhenClosed = false
    win.minSize = NSSize(width: 500, height: 200)

    let container = NSView(frame: contentRect)
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    self.container = container
    self.window = win
  }

  // MARK: - Per-session terminal lifecycle

  /// Return the cached terminal view for `session`, lazy-creating and
  /// starting a fresh shell rooted at the session's worktree if none exists.
  private func terminal(for session: Session) -> ClaudeTerminalView {
    if let existing = terminals[session.id] {
      return existing
    }
    let tv = ClaudeTerminalView(frame: .zero)
    tv.translatesAutoresizingMaskIntoConstraints = false
    tv.nativeForegroundColor = Theme.text1
    tv.nativeBackgroundColor = Theme.bg
    tv.selectedTextBackgroundColor = Theme.selected
    tv.caretColor = Theme.accent
    tv.font = Theme.mono(13)

    let sessionID = session.id
    tv.onProcessExit = { [weak self] _ in
      DispatchQueue.main.async { self?.handleProcessExit(for: sessionID) }
    }

    terminals[session.id] = tv

    let dir = session.worktreePath ?? SessionManager.shared.projectDir
    startShell(in: tv, workingDirectory: dir)
    return tv
  }

  /// Mount `tv` in the floating window's container, replacing whatever was
  /// previously shown. No-op if `tv` is already the installed view.
  private func install(_ tv: ClaudeTerminalView, for session: Session) {
    guard let container = container else { return }
    if currentlyInstalledSessionID == session.id, tv.superview === container {
      window?.title = "Quick Terminal — \(session.displayName)"
      return
    }
    // Drop any currently installed view (don't tear down its shell —
    // we want to swap back to it later with state intact).
    for sub in container.subviews { sub.removeFromSuperview() }

    container.addSubview(tv)
    NSLayoutConstraint.activate([
      tv.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.titlebarInset),
      tv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      tv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      tv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    currentlyInstalledSessionID = session.id
    window?.title = "Quick Terminal — \(session.displayName)"
  }

  /// Called when a session's quick-terminal shell exits (user typed `exit`).
  /// Drop the cached view; if it was the visible one, hide the window so
  /// the next Cmd+` for that session lazy-rebuilds a fresh shell.
  private func handleProcessExit(for sessionID: UUID) {
    terminals.removeValue(forKey: sessionID)
    if currentlyInstalledSessionID == sessionID {
      currentlyInstalledSessionID = nil
      for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
      window?.orderOut(nil)
    }
  }

  // MARK: - Session notifications

  @objc private func activeSessionDidChange() {
    // Only swap eagerly while the window is visible — otherwise wait for
    // the next show() so we don't spin up a shell for a session the user
    // may never quick-terminal into.
    guard let win = window, win.isVisible else { return }
    guard let active = SessionManager.shared.activeSession else {
      currentlyInstalledSessionID = nil
      for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
      win.orderOut(nil)
      return
    }
    let tv = terminal(for: active)
    install(tv, for: active)
    win.makeFirstResponder(tv)
  }

  @objc private func sessionsDidChange() {
    // Drop cached terminal views for sessions that no longer exist.
    let liveIDs = Set(SessionManager.shared.sessions.map(\.id))
    let orphaned = terminals.keys.filter { !liveIDs.contains($0) }
    for id in orphaned {
      terminals.removeValue(forKey: id)
      if currentlyInstalledSessionID == id {
        currentlyInstalledSessionID = nil
        for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
        window?.orderOut(nil)
      }
    }
  }

  // MARK: - Shell startup

  private func startShell(in tv: ClaudeTerminalView, workingDirectory: String?) {
    let parentEnv = ProcessInfo.processInfo.environment
    let shell = SessionManager.resolveShellPath(parentEnv: parentEnv)

    // Match the PATH composition used for Claude sessions so tools installed
    // via Homebrew are available here too.
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inheritedPath = parentEnv["PATH"] ?? ""
    let inheritedParts = inheritedPath.split(separator: ":").map(String.init)
    let composedPath = (homebrewPaths.filter { !inheritedParts.contains($0) } + inheritedParts)
      .joined(separator: ":")

    var envDict: [String: String] = [
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "LANG": parentEnv["LANG"] ?? "en_US.UTF-8",
      "PATH": composedPath,
      "SHELL": shell,
      "HOME": parentEnv["HOME"] ?? NSHomeDirectory(),
      "USER": parentEnv["USER"] ?? NSUserName(),
      "LOGNAME": parentEnv["LOGNAME"] ?? NSUserName(),
    ]
    for key in ["LC_ALL", "LC_CTYPE", "TMPDIR", "TZ", "DISPLAY"] {
      if let v = parentEnv[key] { envDict[key] = v }
    }
    let env: [String] = envDict.map { "\($0.key)=\($0.value)" }

    tv.startProcess(
      executable: shell,
      args: ["--login"],
      environment: env,
      execName: nil)

    // Login shell lands in $HOME; cd into the session's worktree so the
    // quick terminal opens where the user is working. `clear` wipes the
    // login banner so a fresh shell looks clean. Done once at creation —
    // never on show/hide, so scrollback survives toggling.
    if let dir = workingDirectory {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        tv.send(txt: "cd \(shellEscape(dir)) && clear\r")
      }
    }
  }

  /// Anchor the window near the top-center of the main window's screen so it
  /// behaves like a drop-down quick terminal.
  private func positionAtTop(of win: NSWindow) {
    let screen = NSApp.mainWindow?.screen ?? win.screen ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = win.frame.size
    let x = frame.midX - size.width / 2
    let y = frame.maxY - size.height - 20
    win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
  }
}

/// Quote a path so it survives a single-line shell command.
private func shellEscape(_ path: String) -> String {
  "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
