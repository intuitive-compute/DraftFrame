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

  /// In-flight loading state for sessions whose shell is still booting.
  /// Present only while a fresh shell renders its banner and runs the
  /// `cd && clear` bootstrap; cleared once the shell settles.
  private var loads: [UUID: LoadState] = [:]

  /// Tracks one booting shell: the overlay shown over it, the timers that
  /// decide when it's settled, and the rolling scan for the ready marker.
  private final class LoadState {
    let overlay: TerminalLoadingOverlay
    var settleTimer: Timer?
    var maxTimer: Timer?
    /// True once the invisible ready marker has been observed in the PTY
    /// stream — the shell has finished sourcing rc files and run the
    /// bootstrap. Quiescence only counts toward "ready" after this.
    var sawMarker = false
    /// Rolling window of recent printable bytes, scanned for the marker.
    var scanBuffer = ""
    init(overlay: TerminalLoadingOverlay) { self.overlay = overlay }
  }

  /// Container inset matching the transparent titlebar so content doesn't
  /// render behind the traffic lights.
  private static let titlebarInset: CGFloat = 28

  /// Token emitted (invisibly, inside an OSC sequence) by the bootstrap once
  /// the shell is ready. Split across printf's format and argument so the
  /// literal token never appears in the shell's echo of the typed command —
  /// only the actual emission matches.
  private static let readyToken = "DFQT_READY"

  /// Once the marker is seen, how long the prompt must stay quiet before we
  /// reveal — just long enough to let the fresh prompt paint.
  private static let settleQuiet: TimeInterval = 0.15

  /// Hard ceiling on the loading overlay so a shell that never emits the
  /// marker (exotic shell, wedged rc file) still reveals itself.
  private static let maxLoad: TimeInterval = 6.0

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
        focusInstalledContent()
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
    focusInstalledContent()
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
    tv.font = Theme.terminalMono(13)

    let sessionID = session.id
    tv.onProcessExit = { [weak self] _ in
      DispatchQueue.main.async { self?.handleProcessExit(for: sessionID) }
    }

    terminals[session.id] = tv

    // Cover the booting shell with a loading overlay until it settles. The
    // overlay is mounted by install() and torn down by finishLoading().
    let overlay = TerminalLoadingOverlay(message: "Starting terminal…", style: .zoom)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    loads[session.id] = LoadState(overlay: overlay)

    let dir = session.worktreePath ?? SessionManager.shared.projectDir
    startShell(in: tv, for: session, workingDirectory: dir)
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

    // If this shell is still booting, lay its loading overlay on top of the
    // terminal (added after `tv`, so it's above it in z-order).
    if let overlay = loads[session.id]?.overlay {
      container.addSubview(overlay)
      NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: tv.topAnchor),
        overlay.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: tv.trailingAnchor),
        overlay.bottomAnchor.constraint(equalTo: tv.bottomAnchor),
      ])
    }

    currentlyInstalledSessionID = session.id
    window?.title = "Quick Terminal — \(session.displayName)"
  }

  /// Make the installed session's terminal the first responder — unless it's
  /// still booting, in which case focus its loading overlay so typed-ahead
  /// keystrokes are swallowed rather than corrupting the bootstrap command.
  private func focusInstalledContent() {
    guard let win = window, let id = currentlyInstalledSessionID else { return }
    if let overlay = loads[id]?.overlay {
      win.makeFirstResponder(overlay)
    } else if let tv = terminals[id] {
      win.makeFirstResponder(tv)
    }
  }

  /// Called when a session's quick-terminal shell exits (user typed `exit`).
  /// Drop the cached view; if it was the visible one, hide the window so
  /// the next Cmd+` for that session lazy-rebuilds a fresh shell.
  private func handleProcessExit(for sessionID: UUID) {
    terminals.removeValue(forKey: sessionID)
    cancelLoading(for: sessionID)
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
    focusInstalledContent()
  }

  @objc private func sessionsDidChange() {
    // Drop cached terminal views for sessions that no longer exist.
    let liveIDs = Set(SessionManager.shared.sessions.map(\.id))
    let orphaned = terminals.keys.filter { !liveIDs.contains($0) }
    for id in orphaned {
      terminals.removeValue(forKey: id)
      cancelLoading(for: id)
      if currentlyInstalledSessionID == id {
        currentlyInstalledSessionID = nil
        for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
        window?.orderOut(nil)
      }
    }
  }

  // MARK: - Shell startup

  private func startShell(
    in tv: ClaudeTerminalView, for session: Session, workingDirectory: String?
  ) {
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

    let sessionID = session.id

    // Watch the raw PTY stream for the invisible ready marker. dataReceived
    // (and thus onPtyData) fires on the main thread, so timer scheduling and
    // mutation of the load's scan state here are safe. Once the marker is
    // seen the shell is genuinely ready; a short quiescence after lets the
    // fresh prompt paint before we reveal.
    tv.onPtyData = { [weak self] slice in
      guard let self = self, let load = self.loads[sessionID] else { return }
      if !load.sawMarker {
        self.appendToScanBuffer(slice, of: load)
        guard load.scanBuffer.contains(Self.readyToken) else { return }
        load.sawMarker = true
      }
      self.scheduleSettle(for: sessionID)
    }

    // Login shell lands in $HOME; cd into the session's worktree so the quick
    // terminal opens where the user is working. `clear` wipes the login
    // banner so a fresh shell looks clean, then the bootstrap prints the
    // ready marker. Done once at creation — never on show/hide, so scrollback
    // survives toggling. The kernel buffers this until the shell reads it, so
    // it runs only after rc files finish sourcing. The loading overlay blocks
    // input until then so typed-ahead characters can't interleave with the
    // buffered command and break the `cd` path.
    let cdPrefix = workingDirectory.map { "cd \(shellEscape($0)) && " } ?? ""
    tv.send(txt: "\(cdPrefix)clear; \(Self.readyMarkerCommand)\r")

    // Hard ceiling so the overlay never sticks if the marker never arrives.
    loads[sessionID]?.maxTimer = Timer.scheduledTimer(
      withTimeInterval: Self.maxLoad, repeats: false
    ) { [weak self] _ in
      self?.finishLoading(for: sessionID)
    }
  }

  /// Shell command that emits `readyToken` inside an unused OSC sequence —
  /// invisible in the terminal but present in the raw byte stream. The token
  /// is split across printf's format and `%s` argument so the shell's echo of
  /// the typed line never contains it literally (which would match early).
  private static let readyMarkerCommand =
    "printf '\\033]5379;DFQT_%s\\007' 'READY'"

  // MARK: - Loading lifecycle

  /// Append the printable ASCII of `slice` to the load's rolling scan buffer,
  /// capped so it stays cheap to search. Non-printable bytes (the marker's
  /// surrounding ESC/BEL) are dropped, which is fine — the token is ASCII.
  private func appendToScanBuffer(_ slice: ArraySlice<UInt8>, of load: LoadState) {
    for byte in slice where byte >= 0x20 && byte < 0x7F {
      load.scanBuffer.append(Character(UnicodeScalar(byte)))
    }
    if load.scanBuffer.count > 256 {
      load.scanBuffer = String(load.scanBuffer.suffix(256))
    }
  }

  /// (Re)arm the quiescence timer: once the marker has been seen, when PTY
  /// output then stays quiet for `settleQuiet`, the shell is ready.
  private func scheduleSettle(for sessionID: UUID) {
    guard let load = loads[sessionID], load.sawMarker else { return }
    load.settleTimer?.invalidate()
    load.settleTimer = Timer.scheduledTimer(
      withTimeInterval: Self.settleQuiet, repeats: false
    ) { [weak self] _ in
      self?.finishLoading(for: sessionID)
    }
  }

  /// Shell is ready: stop watching, fade out the overlay, and hand focus to
  /// the terminal if this session is the visible one.
  private func finishLoading(for sessionID: UUID) {
    guard let load = loads.removeValue(forKey: sessionID) else { return }
    load.settleTimer?.invalidate()
    load.maxTimer?.invalidate()
    terminals[sessionID]?.onPtyData = nil
    load.overlay.fadeOut { [weak self] in
      guard let self = self,
        self.currentlyInstalledSessionID == sessionID,
        let win = self.window, win.isKeyWindow,
        let tv = self.terminals[sessionID]
      else { return }
      win.makeFirstResponder(tv)
    }
  }

  /// Abandon loading without revealing (shell exited, session deleted).
  private func cancelLoading(for sessionID: UUID) {
    guard let load = loads.removeValue(forKey: sessionID) else { return }
    load.settleTimer?.invalidate()
    load.maxTimer?.invalidate()
    load.overlay.removeFromSuperview()
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
